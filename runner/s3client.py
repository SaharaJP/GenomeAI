import os, boto3, botocore

S3_ENDPOINT = os.environ.get("S3_ENDPOINT", "http://minio:9000")
S3_ACCESS_KEY = os.environ.get("S3_ACCESS_KEY", "miniokey")
S3_SECRET_KEY = os.environ.get("S3_SECRET_KEY", "miniopass")
S3_BUCKET_RUNS = os.environ.get("S3_BUCKET_RUNS", "runs")

def client():
    return boto3.client(
        "s3",
        endpoint_url=S3_ENDPOINT,
        aws_access_key_id=S3_ACCESS_KEY,
        aws_secret_access_key=S3_SECRET_KEY,
    )

def ensure_bucket():
    s3 = client()
    try:
        s3.head_bucket(Bucket=S3_BUCKET_RUNS)
    except botocore.exceptions.ClientError:
        s3.create_bucket(Bucket=S3_BUCKET_RUNS)
