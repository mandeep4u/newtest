from google.oauth2 import service_account
from googleapiclient import discovery
from scripts.gcp.get_auth import get_credentials

def create_service_account(project_id, service_account_id, service_account_display_name):
    service_account_email = f"{service_account_id}@{project_id}.iam.gserviceaccount.com"
    name = f'projects/{project_id}'

    try:
        request_body = {
            'accountId': service_account_id,
            'serviceAccount': {
                'displayName': service_account_display_name
            }
        }

        response = iam_service.projects().serviceAccounts().create(
            name=name,
            body=request_body
        ).execute()

        print(f"Created service account: {response['email']}")
        return service_account_email

    except Exception as e:
        if 'already exists' in str(e):
            print(f"Service account already exists: {service_account_email}")
            return service_account_email
        else:
            raise

def assign_roles_to_sa_in_project(sa_email, target_project_id, roles):
    for role in roles:
        policy = crm_service.projects().getIamPolicy(
            resource=target_project_id,
            body={}
        ).execute()

        binding_exists = False
        for binding in policy['bindings']:
            if binding['role'] == role:
                if sa_email in binding['members']:
                    binding_exists = True
                    break
                else:
                    binding['members'].append(f"serviceAccount:{sa_email}")
                    binding_exists = True
                    break

        if not binding_exists:
            policy['bindings'].append({
                'role': role,
                'members': [f"serviceAccount:{sa_email}"]
            })

        set_policy_request = {
            'policy': policy
        }

        crm_service.projects().setIamPolicy(
            resource=target_project_id,
            body=set_policy_request
        ).execute()

        print(f"Assigned role '{role}' to {sa_email} in project {target_project_id}")

# === Main ===
if __name__ == '__main__':
    # Initialize clients
    credentials = get_credentials()
    iam_service = discovery.build('iam', 'v1', credentials=credentials)
    crm_service = discovery.build('cloudresourcemanager', 'v1', credentials=credentials)

    # Define parameters
    project_a = "test2-b-468317"  # Where SA will be created
    project_b = "test1-a-468317"     # Where roles will be assigned
    service_account_id = "sa-test1-a-468317"
    service_account_display_name = "GCP test1-a-468317 Service Account"

    roles_to_assign = [
        "roles/viewer",
    ]

    # Create SA and assign roles
    sa_email = create_service_account(project_a, service_account_id, service_account_display_name)
    assign_roles_to_sa_in_project(sa_email, project_b, roles_to_assign)
