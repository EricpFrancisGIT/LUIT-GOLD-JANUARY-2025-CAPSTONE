import os, json, boto3
from datetime import datetime, timedelta, timezone

ec2 = boto3.client("ec2")
cw  = boto3.client("cloudwatch")
s3  = boto3.client("s3")
ddb = boto3.client("dynamodb")

PROJECT    = os.getenv("PROJECT","levelup")
ENVIRONMENTS = os.getenv("ENVIRONMENTS","staging,prod").split(",")
BUCKET     = os.getenv("S3_BUCKET")
TABLE      = os.getenv("DDB_TABLE")
NS         = os.getenv("METRIC_NS","LevelUp/CostOps")
CPU_IDLE_THRESHOLD = float(os.getenv("CPU_IDLE_THRESHOLD","5"))
CPU_IDLE_DAYS      = int(os.getenv("CPU_IDLE_DAYS","7"))
S3_EMPTY_DAYS      = int(os.getenv("S3_EMPTY_DAYS","30"))

PRICES = {"t3.micro":0.0104,"t3.small":0.0208,"t3.medium":0.0416}

def price(itype): return PRICES.get(itype, 0.05)

def put_metric(name, value, env, unit="Count"):
    cw.put_metric_data(Namespace=NS, MetricData=[{
        "MetricName":name,"Dimensions":[{"Name":"Env","Value":env}], "Unit":unit, "Value":float(value)
    }])

def list_instances():
    paginator = ec2.get_paginator("describe_instances")
    for page in paginator.paginate():
        for r in page.get("Reservations", []):
            for i in r.get("Instances", []):
                yield i

def cpu_avg(instance_id, days):
    end = datetime.now(timezone.utc); start = end - timedelta(days=days)
    resp = cw.get_metric_statistics(Namespace="AWS/EC2", MetricName="CPUUtilization",
           Dimensions=[{"Name":"InstanceId","Value":instance_id}], StartTime=start, EndTime=end,
           Period=3600, Statistics=["Average"])
    dps = resp.get("Datapoints", [])
    return sum(dp["Average"] for dp in dps)/len(dps) if dps else 0.0

def s3_idle(bucket):
    try:
        resp = s3.list_objects_v2(Bucket=bucket, MaxKeys=1)
        if resp.get("KeyCount",0)==0: return True, "empty"
        last = max(o["LastModified"] for o in resp.get("Contents",[]))
        age = (datetime.now(timezone.utc) - last).days
        return (age >= S3_EMPTY_DAYS, f"no recent objects ({age}d)")
    except Exception as e:
        return False, f"error:{e}"

def handler(event, context):
    run_ts = datetime.utcnow().strftime("%Y%m%dT%H%M%SZ")
    summary = {}

    for env in ENVIRONMENTS:
        idle_ec2, idle_s3 = [], []

        # EC2 pass
        for inst in list_instances(state_names=("running",)):
            iid   = inst["InstanceId"]
            itype = inst.get("InstanceType", "unknown")
            state = inst.get("State", {}).get("Name")
            tags  = {t["Key"]: t["Value"] for t in inst.get("Tags", [])}
            if tags.get("Env", "staging") != env or state != "running":
                continue

            avg = cpu_avg(iid, CPU_IDLE_DAYS)
            if avg is None:
                continue  # insufficient data (if you adopt the hardened cpu_avg)
            if avg < CPU_IDLE_THRESHOLD:
                est = round(price(itype) * 24 * 30, 2)
                idle_ec2.append({
                    "resource_id": iid,
                    "resource_type": "ec2",
                    "env": env,
                    "last_seen": run_ts,
                    "idle_reason": f"CPU<{CPU_IDLE_THRESHOLD}% avg {CPU_IDLE_DAYS}d ({avg:.2f}%)",
                    "metrics_snapshot": {"cpu_avg": avg, "days": CPU_IDLE_DAYS},
                    "estimated_monthly_cost_savings": est,
                    "risk_flags": ["missing-tags"] if "Name" not in tags else []
                })

        # S3 pass (filter buckets to this env via tag)
        for b in s3.list_buckets()["Buckets"]:
            name = b["Name"]
            try:
                tagset = s3.get_bucket_tagging(Bucket=name).get("TagSet", [])
                btags  = {t["Key"]: t["Value"] for t in tagset}
            except Exception:
                btags = {}
            if btags.get("Env") != env:
                continue

            is_idle, reason = s3_idle(name)
            if is_idle:
                idle_s3.append({
                    "resource_id": name,
                    "resource_type": "s3",
                    "env": env,
                    "last_seen": run_ts,
                    "idle_reason": f"S3 {reason}",
                    "metrics_snapshot": {},
                    "estimated_monthly_cost_savings": 0.0,
                    "risk_flags": []
                })

        findings = idle_ec2 + idle_s3
        totals = {
            "ec2": len(idle_ec2),
            "s3": len(idle_s3),
            "overall": len(findings),
            "estimated_monthly_cost_savings": round(sum(f["estimated_monthly_cost_savings"] for f in findings), 2),
        }

        # Metrics
        put_metric("IdleEC2Count", totals["ec2"], env)
        put_metric("IdleS3Count", totals["s3"], env)
        put_metric("FindingsTotal", totals["overall"], env)
        put_metric("EstimatedMonthlySavings", totals["estimated_monthly_cost_savings"], env, unit="None")

        # Persist findings (consider batch_writer or a single report)
        for f in findings:
            ddb.put_item(TableName=TABLE, Item={
                "pk":    {"S": env},
                "sk":    {"S": f"{run_ts}#{f['resource_type']}#{f['resource_id']}"},
                "gsi1pk":{"S": f"run#{env}"},
                "gsi1sk":{"S": run_ts},
                "payload":{"S": json.dumps(f)}
            })

        # Optional: write full report file
        report_obj = {"run_id": run_ts, "env": env, "totals": totals, "findings": findings}
        s3.put_object(Bucket=BUCKET, Key=f"{env}/reports/{run_ts}.json",
                      Body=json.dumps(report_obj).encode("utf-8"), ContentType="application/json")

        summary[env] = totals

    return {"ok": True, "run_id": run_ts, "summary": summary}
