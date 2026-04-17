ansible-playbook main.yml -i inv \
  -e kubernetes_target_version=1.35.4-1.1 \
  -e kubernetes_target_minor=v1.35
