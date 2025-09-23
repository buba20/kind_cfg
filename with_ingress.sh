# /usr/bin/env bash

echo "Create custer with name $1"

CLUSTER_NAME=$1
cat <<EOF | kind create cluster --name "${CLUSTER_NAME}" --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
  extraPortMappings:
  - containerPort: 80
    hostPort: 80
    protocol: TCP
  - containerPort: 443
    hostPort: 443
    protocol: TCP
EOF

# Run configuration script from website
kubectl apply -f https://kind.sigs.k8s.io/examples/ingress/deploy-ingress-nginx.yaml

# Wait until is ready to process requests running:

kubectl wait -n ingress-nginx --for=condition=Available deployment/ingress-nginx-controller --timeout=90s

# Wait for controller to be ready
kubectl wait -n ingress-nginx \
	--for=condition=Available deployment/ingress-nginx-controller \
	--timeout=90s

# Wait for admission webhook jobs to complete
kubectl wait -n ingress-nginx \
	--for=condition=complete job/ingress-nginx-admission-create \
	--timeout=90s || true

kubectl wait -n ingress-nginx \
	--for=condition=complete job/ingress-nginx-admission-patch \
	--timeout=90s || true

# Wait for the admission service endpoint to actually be ready
kubectl wait -n ingress-nginx \
	--for=condition=ready pod \
	-l app.kubernetes.io/component=controller \
	--timeout=120s

# EXTRA: Wait for the admission service to have ready endpoints
echo "Waiting for admission service endpoints..."
for i in {1..30}; do
	if kubectl -n ingress-nginx get endpoints ingress-nginx-controller-admission \
		-o jsonpath='{.subsets[0].addresses[0].ip}' 2>/dev/null | grep -qE '^[0-9]'; then
		echo "Admission service is ready"
		break
	fi
	echo "Still waiting... ($i/30)"
	sleep 3
done

# The following example creates simple http-echo services and an Ingress object to route to these services.
kubectl create namespace test-ingress

sleep 1s

cat <<EOF | kubectl -n test-ingress apply -f -
kind: Pod
apiVersion: v1
metadata:
  name: foo-app
  labels:
    app: foo
spec:
  containers:
  - command:
    - /agnhost
    - serve-hostname
    - --http=true
    - --port=8080
    image: registry.k8s.io/e2e-test-images/agnhost:2.39
    name: foo-app
    ports:
    - containerPort: 8080
      name: http
---
kind: Service
apiVersion: v1
metadata:
  name: foo-service
spec:
  selector:
    app: foo
  ports:
  # Default port used by the image
  - port: 8080
---
kind: Pod
apiVersion: v1
metadata:
  name: bar-app
  labels:
    app: bar
spec:
  containers:
  - command:
    - /agnhost
    - serve-hostname
    - --http=true
    - --port=8080
    image: registry.k8s.io/e2e-test-images/agnhost:2.39
    name: bar-app
    ports: 
    - containerPort: 8080
      name: http
---
kind: Service
apiVersion: v1
metadata:
  name: bar-service
spec:
  selector:
    app: bar
  ports:
  # Default port used by the image
  - port: 8080
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: example-ingress
spec:
  rules:
  - http:
      paths:
      - pathType: Prefix
        path: /foo
        backend:
          service:
            name: foo-service
            port:
              number: 8080
      - pathType: Prefix
        path: /bar
        backend:
          service:
            name: bar-service
            port:
              number: 8080
---
EOF
