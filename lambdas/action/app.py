import os, json, boto3
from datetime import datetime

ec2=boto3.client("ec2"); s3=boto3.client("s3"); ddb=boto3.client("dynamodb")
PROJECT=os.getenv("PROJECT","levelup"); BUCKET=os.getenv("S3_BUCKET"); TABLE=os.getenv("DDB_TABLE")
ENFORCE_SAFE_TAG=os.getenv("ENFORCE_SAFE_TAG","true").lower()=="true"

def iter_latest_report(env):
    prefix=f"{env}/reports/"
    resp=s3.list_objects_v2(Bucket=BUCKET, Prefix=prefix)
    keys=[c["Key"] for c in resp.get("Contents",[]) if c["Key"].endswith(".json")]; keys.sort(reverse=True)
    if not keys: return None
    obj=s3.get_object(Bucket=BUCKET, Key=keys[0])
    return json.loads(obj["Body"].read())

def handler(event, context):
    run_ts=datetime.utcnow().strftime("%Y%m%dT%H%M%SZ")
    result={}
    for env in ["staging","prod"]:
        rep=iter_latest_report(env)
        if not rep: continue
        actions_taken=[]; skipped=[]; totals={"stopped":0,"tagged":0,"skipped":0,"s3_tagged":0}

        for f in rep["findings"]:
            if f["resource_type"]=="ec2":
                iid=f["resource_id"]
                tags=ec2.describe_instances(InstanceIds=[iid])["Reservations"][0]["Instances"][0].get("Tags",[])
                tagmap={t["Key"]:t["Value"] for t in tags}; allow=tagmap.get("AllowStop","false").lower()=="true"
                if ENFORCE_SAFE_TAG and not allow:
                    skipped.append({"id":iid,"reason":"no AllowStop=true"}); totals["skipped"]+=1; continue
                try:
                    ec2.create_tags(Resources=[iid], Tags=[{"Key":"Idle","Value":"true"}])
                    ec2.stop_instances(InstanceIds=[iid])
                    actions_taken.append({"id":iid,"action":"stopped"}); totals["stopped"]+=1
                except Exception as e:
                    skipped.append({"id":iid,"reason":str(e)}); totals["skipped"]+=1

            elif f["resource_type"]=="s3":
                name=f["resource_id"]
                try:
                    s3.put_bucket_tagging(Bucket=name, Tagging={"TagSet":[{"Key":"Idle","Value":"true"}]})
                    totals["s3_tagged"]+=1; actions_taken.append({"id":name,"action":"tagged"})
                except Exception as e:
                    skipped.append({"id":name,"reason":str(e)}); totals["skipped"]+=1

        ddb.put_item(TableName=TABLE, Item={
            "pk":{"S":f"{env}#summary"}, "sk":{"S":run_ts},
            "gsi1pk":{"S":f"run#{env}"}, "gsi1sk":{"S":run_ts},
            "payload":{"S":json.dumps({"run_id":run_ts,"env":env,"totals":totals,"actions_taken":actions_taken[:20]})}
        })
        result[env]={"totals":totals,"run_id":run_ts}
    return {"ok":True,"summary":result}
