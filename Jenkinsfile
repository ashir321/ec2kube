///////////////////////////////////////////////////////////////////////////////
// Jenkinsfile — Self-Managed Kubernetes on EC2 Deployment Pipeline
//
// Deploys a kubeadm-based Kubernetes cluster on EC2 instances using
// Terraform (networking, instances, node ASG) and Ansible (bootstrap).
///////////////////////////////////////////////////////////////////////////////
pipeline {

    agent any

    parameters {
        choice(name: 'TERRADESTROY',
               choices: ['N', 'Y'],
               description: 'Set to Y to tear down the entire stack')
        choice(name: 'FIRST_DEPLOY',
               choices: ['N', 'Y'],
               description: 'Set to Y on the very first run to create the state bucket')
        choice(name: 'SKIP',
               choices: ['N', 'Y'],
               description: 'Set to Y to skip deployment stages')
        string(name: 'AWS_REGION',
               defaultValue: 'us-east-1',
               description: 'AWS region')
        string(name: 'STATE_BUCKET',
               defaultValue: '',
               description: 'S3 bucket for Terraform remote state')
        string(name: 'ANSIBLE_BUCKET_NAME',
               defaultValue: '',
               description: 'S3 bucket used by Ansible for inventory exchange')
    }

    environment {
        AWS_ACCESS_KEY_ID     = credentials('awsaccesskey')
        AWS_SECRET_ACCESS_KEY = credentials('awssecretkey')
        AWS_DEFAULT_REGION    = "${params.AWS_REGION ?: 'us-east-1'}"
        SKIP                  = "${params.SKIP ?: 'N'}"
        TERRADESTROY          = "${params.TERRADESTROY ?: 'N'}"
        FIRST_DEPLOY          = "${params.FIRST_DEPLOY ?: 'N'}"
        STATE_BUCKET          = "${params.STATE_BUCKET ?: ''}"
        ANSIBLE_BUCKET_NAME   = "${params.ANSIBLE_BUCKET_NAME ?: ''}"
    }

    options {
        timestamps()
        timeout(time: 60, unit: 'MINUTES')
        ansiColor('xterm')
    }

    stages {

        // ── Prerequisite checks ─────────────────────────────────────────
        stage('Verify Prerequisites') {
            when {
                environment name: 'TERRADESTROY', value: 'N'
                environment name: 'SKIP', value: 'N'
            }
            steps {
                sh '''
                echo "=== Checking required CLIs ==="
                terraform version
                ansible --version
                aws --version
                echo ""
                echo "=== AWS Identity ==="
                aws sts get-caller-identity
                '''
            }
        }

        // ── State bucket ────────────────────────────────────────────────
        stage('Create Terraform State Bucket') {
            when {
                environment name: 'FIRST_DEPLOY', value: 'Y'
                environment name: 'TERRADESTROY', value: 'N'
                environment name: 'SKIP', value: 'N'
            }
            steps {
                sh '''
                echo "=== Creating state bucket ==="
                aws s3 mb "s3://${STATE_BUCKET}" --region "${AWS_DEFAULT_REGION}" || true
                '''
            }
        }

        // ── Ansible infra ───────────────────────────────────────────────
        stage('Deploy Ansible Infra') {
            when {
                environment name: 'TERRADESTROY', value: 'N'
                environment name: 'SKIP', value: 'N'
            }
            stages {
                stage('Validate Ansible Infra') {
                    steps {
                        sh '''
                        cd ansible_infra
                        terraform init -input=false
                        terraform validate
                        '''
                    }
                }
                stage('Apply Ansible Infra') {
                    steps {
                        sh '''
                        cd ansible_infra
                        terraform plan -out=tfplan -input=false
                        terraform apply -auto-approve -input=false tfplan
                        '''
                    }
                }
            }
        }

        // ── Networking ──────────────────────────────────────────────────
        stage('Deploy Networking') {
            when {
                environment name: 'TERRADESTROY', value: 'N'
                environment name: 'SKIP', value: 'N'
            }
            stages {
                stage('Validate Networking') {
                    steps {
                        sh '''
                        cd networking
                        terraform init -input=false
                        terraform validate
                        '''
                    }
                }
                stage('Apply Networking') {
                    steps {
                        sh '''
                        cd networking
                        terraform plan -out=tfplan -input=false
                        terraform apply -auto-approve -input=false tfplan
                        '''
                    }
                }
            }
        }

        // ── Control Plane ───────────────────────────────────────────────
        stage('Deploy Controlplane') {
            when {
                environment name: 'TERRADESTROY', value: 'N'
                environment name: 'SKIP', value: 'N'
            }
            stages {
                stage('Validate Instances') {
                    steps {
                        sh '''
                        cd instances
                        terraform init -input=false
                        terraform validate
                        '''
                    }
                }
                stage('Apply Instances') {
                    steps {
                        sh '''
                        cd instances
                        terraform plan -out=tfplan -input=false
                        terraform apply -auto-approve -input=false tfplan
                        '''
                    }
                }
                stage('Prepare Inventory') {
                    steps {
                        sh """
                        cd ansible_infra/ansible_playbooks
                        ansible-playbook identify_controlplane.yml -i inv
                        """
                    }
                }
                stage('Bootstrap Control Plane') {
                    steps {
                        sh """
                        cd ansible_infra/ansible_role
                        aws s3 cp "s3://${ANSIBLE_BUCKET_NAME}/inv" inv
                        ansible-playbook main.yml -i inv
                        """
                    }
                }
                stage('Verify kubectl') {
                    steps {
                        sh """
                        cd ansible_infra/ansible_playbooks
                        aws s3 cp "s3://${ANSIBLE_BUCKET_NAME}/inv" inv
                        ansible-playbook testkubectl.yml -i inv
                        """
                    }
                }
            }
        }

        // ── Worker Nodes ────────────────────────────────────────────────
        stage('Launch Nodes') {
            when {
                environment name: 'TERRADESTROY', value: 'N'
                environment name: 'SKIP', value: 'N'
            }
            stages {
                stage('Validate ASG') {
                    steps {
                        sh '''
                        cd node_asg
                        terraform init -input=false
                        terraform validate
                        '''
                    }
                }
                stage('Apply ASG') {
                    steps {
                        sh '''
                        cd node_asg
                        terraform plan -out=tfplan -input=false
                        terraform apply -auto-approve -input=false tfplan
                        '''
                    }
                }
                stage('Generate Join Token') {
                    steps {
                        sh """
                        cd ansible_infra/ansible_playbooks
                        aws s3 cp "s3://${ANSIBLE_BUCKET_NAME}/inv" inv
                        ansible-playbook main_kubeadm_token.yml -i inv
                        """
                    }
                }
                stage('Update Node Inventory') {
                    steps {
                        sh """
                        cd ansible_infra/ansible_playbooks
                        aws s3 cp "s3://${ANSIBLE_BUCKET_NAME}/inv" inv
                        ansible-playbook identify_nodes.yml -i inv
                        """
                    }
                }
                stage('Bootstrap Nodes') {
                    steps {
                        sh """
                        cd ansible_infra/ansible_role
                        aws s3 cp "s3://${ANSIBLE_BUCKET_NAME}/nodeinv" nodeinv
                        ansible-playbook kubenode.yml -i nodeinv

                        cd ../ansible_playbooks
                        aws s3 cp "s3://${ANSIBLE_BUCKET_NAME}/nodeinv" nodeinv
                        ansible-playbook bootstrap_node.yml -i nodeinv
                        """
                    }
                }
                stage('Verify Nodes') {
                    steps {
                        sh """
                        cd ansible_infra/ansible_playbooks
                        aws s3 cp "s3://${ANSIBLE_BUCKET_NAME}/inv" inv
                        ansible-playbook testkubectl.yml -i inv
                        """
                    }
                }
            }
        }

        // ── Teardown ────────────────────────────────────────────────────
        stage('Teardown') {
            when {
                environment name: 'TERRADESTROY', value: 'Y'
            }
            stages {
                stage('Destroy Node ASG') {
                    steps {
                        sh '''
                        cd node_asg
                        terraform init -input=false
                        terraform destroy -auto-approve -input=false
                        '''
                    }
                }
                stage('Destroy Instances') {
                    steps {
                        sh '''
                        cd instances
                        terraform init -input=false
                        terraform destroy -auto-approve -input=false
                        '''
                    }
                }
                stage('Destroy Networking') {
                    steps {
                        sh '''
                        cd networking
                        terraform init -input=false
                        terraform destroy -auto-approve -input=false
                        '''
                    }
                }
                stage('Destroy Ansible Infra') {
                    steps {
                        sh '''
                        cd ansible_infra
                        terraform init -input=false
                        terraform destroy -auto-approve -input=false
                        '''
                    }
                }
                stage('Destroy State Bucket') {
                    steps {
                        sh '''
                        aws s3 rb "s3://${STATE_BUCKET}" --force || true
                        '''
                    }
                }
            }
        }
    }

    post {
        success {
            echo 'Pipeline completed successfully.'
        }
        failure {
            echo 'Pipeline failed. Check logs above for error details.'
        }
        always {
            cleanWs()
        }
    }
}