import os, json, boto3
from datetime import datetime

s3=boto3.client("s3"); ddb=boto3.client("dynamodb"); sns=boto3.client("sns"); bedrock=boto3.client("bedrock-runtime")

PROJECT=os.getenv("PROJECT","levelup"); BUCKET=os.getenv("S3_BUCKET"); TABLE=os.getenv("DDB_TABLE")
TOPIC_ARN=os.getenv("SNS_TOPIC_ARN"); MODEL_ID=os.getenv("MODEL_ID","anthropic.claude-3-haiku-20240307-v1:0")
TOP_N=int(os.getenv("SUMMARY_TOP_N","5"))

def latest_report(env):
    prefix=f"{env}/reports/"
    resp=s3.list_objects_v2(Bucket=BUCKET, Prefix=prefix)
    keys=[c["Key"] for c in resp.get("Contents",[]) if c["Key"].endswith(".json")]; keys.sort(reverse=True)
    if not keys: return None
    return json.loads(s3.get_object(Bucket=BUCKET, Key=keys[0])["Body"].read())

def load_prompt_template():
    return open("/var/task/prompt_template.txt","r",encoding="utf-8").read()

def invoke_bedrock_claude(messages, model_id):
    resp = bedrock.invoke_model(modelId=model_id, body=json.dumps({
        "anthropic_version":"bedrock-2023-05-31","max_tokens":600,"messages":messages
    }).encode("utf-8"), contentType="application/json", accept="application/json")
    data=json.loads(resp.get("body").read())
    return data["content"][0]["text"]

def handler(event, context):
    run_ts=datetime.utcnow().strftime("%Y%m%dT%H%M%SZ"); results={}
    for env in ["staging","prod"]:
        rep=latest_report(env)
        if not rep: continue
        findings=sorted(rep["findings"], key=lambda f:f.get("estimated_monthly_cost_savings",0), reverse=True)[:TOP_N]
        top_items=[f"- {f['resource_type']} {f['resource_id']}: {f['idle_reason']} (${f.get('estimated_monthly_cost_savings',0)}/mo)" for f in findings]
        risks=set(r for f in findings for r in f.get("risk_flags",[]))
        prompt=load_prompt_template().replace("{{env}}",env).replace("{{top_n}}",str(TOP_N)).replace("{{top_items}}","\n".join(top_items)).replace("{{totals}}",json.dumps(rep.get("totals",{}))).replace("{{risks}}",", ".join(sorted(risks)) if risks else "none")
        text=invoke_bedrock_claude([{"role":"user","content":prompt}], MODEL_ID)
        key=f"{env}/ai_summaries/{run_ts}.txt"
        s3.put_object(Bucket=BUCKET, Key=key, Body=text.encode("utf-8"), ContentType="text/plain")
        sns.publish(TopicArn=TOPIC_ARN, Subject=f"AI Summary ({env})", Message=text)
        results[env]={"summary_key":key}
    return {"ok":True,"results":results}
