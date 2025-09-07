import json, os, boto3, secrets, string

secretsmanager = boto3.client('secretsmanager')
def _random_token(n=40):
    alphabet = string.ascii_letters + string.digits
    return ''.join(secrets.choice(alphabet) for _ in range(n))

def handler(event, context):
    # Simple rotation: set a new random token as the current secret value.
    secret_arn = os.environ['SECRET_ARN']
    token = _random_token()
    secretsmanager.put_secret_value(SecretId=secret_arn, SecretString=token)
    return {"status":"rotated"}
