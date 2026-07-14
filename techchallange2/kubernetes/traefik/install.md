kubectl apply --server-side -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.6.0/standard-install.yaml

helm repo add traefik https://traefik.github.io/charts
helm repo update
# Install
helm install traefik traefik/traefik -n traefik -f values.yaml --wait