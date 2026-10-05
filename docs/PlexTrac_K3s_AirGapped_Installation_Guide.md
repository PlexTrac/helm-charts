# PlexTrac K3s Air-Gapped Installation Guide

Install PlexTrac on a single-node K3s server that has no internet access. You download
everything on a connected **staging host**, carry it to the **PlexTrac server**, and install
from local files. No container registry is needed inside the air gap.

Throughout this guide, replace `plextrac.mycompany.com` with your PlexTrac hostname.

> **Requires PlexTrac chart 2.29.0 or later.** Earlier chart versions hardcode
> `imagePullPolicy: Always` on most containers, so every pod start tries to reach a registry
> and fails without internet access.

## How it works

- K3s imports every image archive in `/var/lib/rancher/k3s/agent/images/` when it starts, and
  any archive added there while it runs. It pins those images so they are never garbage
  collected.
- `global.image.pullPolicy: IfNotPresent` makes every PlexTrac container use the image already
  on the node instead of contacting a registry.
- The image list is rendered from your own values file, so the bundle contains exactly the
  images your configuration uses, including any optional components you enable.
- TLS uses a certificate you supply, ideally from your internal CA. cert-manager and
  Let's Encrypt are not used.

## Versions

| Component | Version | Notes |
|---|---|---|
| K3s | `v1.35.9+k3s1` | Kubernetes 1.35, the newest minor the final ingress-nginx release supports |
| ingress-nginx chart | `4.15.1` (controller `v1.15.1`) | Final release: the project was [retired upstream](https://www.kubernetes.dev/blog/2025/11/12/ingress-nginx-retirement/) in March 2026. Supports Kubernetes 1.31 to 1.35 |
| Helm | `v3.22.0` | Helm 3, as used by this chart's CI. Helm 3 security fixes end February 10, 2027 |
| k3s-selinux | `1.6-1.el9` (release `v1.6.stable.1`) | SELinux policy for K3s on RHEL 9 |

Newer patch releases are fine. If you change the K3s minor version, stay within the Kubernetes
versions ingress-nginx 1.15 supports.

## Requirements

**Staging host** (connected):

- x86_64 Linux with Docker, `git`, `curl`, `sha256sum`, and Helm 3.10 or newer
  ([Install Helm](user-guide.md#install-helm)). Use an x86_64 machine: on arm64 (for example
  Apple Silicon), `docker save` can fail or export images that do not run on the server.
- Outbound access to `github.com`, `get.k3s.io`, `get.helm.sh`, `kubernetes.github.io`,
  `registry.k8s.io`, Docker Hub, and `docker.cke-cs.com`.
- The registry logins PlexTrac provided: the PlexTrac image registry and CKEditor
  (`docker.cke-cs.com`). These are the same credentials a connected install puts in
  `.env.local`.
- Free disk for the pulled images plus their archives.

**PlexTrac server** (air-gapped):

- RHEL 9 or a compatible rebuild (Rocky Linux 9, AlmaLinux 9), x86_64.
- At least 4 vCPU, 16 GiB RAM, and 100 GiB disk (see
  [user guide Step 1.1](user-guide.md#step-11--provision-a-kubernetes-cluster)), plus room under
  `/var/lib/rancher` for the image archives and the unpacked images.
- `container-selinux`, `selinux-policy-base`, and `policycoreutils` installed, or available from
  your internal RHEL repository or install media.
- A hostname in your internal DNS that you can point at the server, and a TLS certificate and
  key for that hostname.
- Not currently running PlexTrac on docker-compose. To move an existing docker-compose install
  to K3s, use the [docker-compose to k3s migration guide](runbooks/docker-compose_to_k3s_guide.md).

---

## Part 1: Build the bundle on the staging host

### 1.1 Set versions

```bash
export K3S_VERSION="v1.35.9+k3s1"
export INGRESS_NGINX_VERSION="4.15.1"
export HELM_VERSION="v3.22.0"
export K3S_SELINUX_RELEASE="v1.6.stable.1"
export K3S_SELINUX_RPM="k3s-selinux-1.6-1.el9.noarch.rpm"

mkdir -p ~/plextrac-airgap && cd ~/plextrac-airgap
```

### 1.2 Download K3s, the SELinux policy, and Helm

```bash
K3S_URL="https://github.com/k3s-io/k3s/releases/download/${K3S_VERSION/+/%2B}"
curl -fLO "${K3S_URL}/k3s"
curl -fLO "${K3S_URL}/k3s-airgap-images-amd64.tar.zst"
curl -fLO "${K3S_URL}/sha256sum-amd64.txt"
grep -E ' (k3s|k3s-airgap-images-amd64\.tar\.zst)$' sha256sum-amd64.txt | sha256sum -c -

curl -sfL https://get.k3s.io -o k3s-install.sh

curl -fLO "https://github.com/k3s-io/k3s-selinux/releases/download/${K3S_SELINUX_RELEASE}/${K3S_SELINUX_RPM}"

curl -fLO "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz"
curl -fLO "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz.sha256sum"
sha256sum -c "helm-${HELM_VERSION}-linux-amd64.tar.gz.sha256sum"
```

Both `sha256sum -c` commands must report `OK` for every file.

### 1.3 Get the charts

```bash
git clone https://github.com/PlexTrac/helm-charts.git
grep '^version:' helm-charts/charts/plextrac/Chart.yaml   # must be 2.29.0 or later

helm pull ingress-nginx --repo https://kubernetes.github.io/ingress-nginx \
  --version "${INGRESS_NGINX_VERSION}"
```

Create the ingress-nginx values for the air gap:

```bash
cat > ingress-nginx-values.yaml <<'EOF'
# Reference the controller images by tag only. By default the chart pins them by registry
# digest, which an image loaded from an archive may not match, so the kubelet would try to
# pull it from registry.k8s.io.
controller:
  image:
    digest: ""
    digestChroot: ""
  admissionWebhooks:
    patch:
      image:
        digest: ""
EOF
```

### 1.4 Create your values file

Create `my-values.yaml` now. The image list in the next step is rendered from it.

```bash
cat > my-values.yaml <<'EOF'
global:
  namespace: plextrac
  createNamespace: false          # you create the namespace on the server (step 2.8)
  imagePullSecrets: []            # images are loaded onto the node; no registry login needed
  image:
    pullPolicy: IfNotPresent      # REQUIRED in an air gap: use the imported images, never pull
  ingress:
    host: plextrac.mycompany.com  # your internal DNS name for PlexTrac
    tlsSecretName: plextrac-tls   # the TLS secret you create on the server (step 2.8)
    certManager:
      issuer: ""                  # no cert-manager or Let's Encrypt in an air gap
    certManagerClusterIssuer: ""

secrets:
  mode: manual
  manual:
    createKubernetesSecrets: true
    generatedSecrets:
      application:
        stringData:
          ADMIN_EMAIL: ""         # optional; leave empty to sign in as global_admin
      shared:
        stringData:
          CKEDITOR_SERVER_LICENSE_KEY: ""   # your CKEditor license key (you can add it on the server)
      tls:
        enabled: false            # the TLS secret is created with kubectl instead
EOF
```

Everything else comes from the chart defaults, as in a connected install. To run the optional
components (Synqly, Keycloak, MCP), add their settings from the
[user guide](user-guide.md#phase-3--configure-your-values-file) now, so their images are in the
bundle. Keycloak also needs its own DNS name and a `keycloak-tls` secret, created the same way as
`plextrac-tls` in step 2.8. Synqly's image is on `quay.io`, so log in there too in step 1.6 if
your account requires it.

### 1.5 Build the image lists

```bash
helm template plextrac ./helm-charts/charts/plextrac --namespace plextrac -f my-values.yaml \
  | grep -E '^[[:space:]]*(- )?image:' | awk '{print $NF}' | tr -d '"' | sort -u \
  > images-plextrac.txt

helm template ingress-nginx "./ingress-nginx-${INGRESS_NGINX_VERSION}.tgz" --namespace ingress-nginx \
  -f ingress-nginx-values.yaml \
  | grep -E '^[[:space:]]*(- )?image:' | awk '{print $NF}' | tr -d '"' | sort -u \
  > images-ingress-nginx.txt

cat images-plextrac.txt images-ingress-nginx.txt
```

With the values above and the chart 2.29.0 defaults, the list is:

```
docker.cke-cs.com/cs:latest
plextrac/minio:latest
plextrac/plextrac-minio-bootstrap:stable
plextrac/plextracapi:stable
plextrac/plextracdb:7.2.0
plextrac/plextracnginx:stable
plextrac/plextracpostgres:stable
redis:8.4.0-alpine
registry.k8s.io/ingress-nginx/controller:v1.15.1
registry.k8s.io/ingress-nginx/kube-webhook-certgen:v1.6.9
```

Confirm that no container will try to pull:

```bash
helm template plextrac ./helm-charts/charts/plextrac --namespace plextrac -f my-values.yaml \
  | grep -c 'imagePullPolicy: Always'
```

This must print `0`. Anything else means the chart is older than 2.29.0 or
`global.image.pullPolicy` is not set.

### 1.6 Pull and save the images

```bash
docker login -u <plextrac-registry-username>                     # Docker Hub, unless PlexTrac gave you another registry
docker login docker.cke-cs.com -u <ckeditor-registry-username>

cat images-plextrac.txt images-ingress-nginx.txt | while read -r image; do
  docker pull --platform linux/amd64 "$image" </dev/null || echo "FAILED: $image"
done
```

If any line says `FAILED`, fix it (usually a missing login) and pull again before you continue.
Then save the images into two archives:

```bash
docker save -o plextrac-images.tar $(cat images-plextrac.txt) && gzip -f plextrac-images.tar
docker save -o ingress-nginx-images.tar $(cat images-ingress-nginx.txt) && gzip -f ingress-nginx-images.tar
```

### 1.7 Package and checksum

```bash
tar -czf helm-charts.tar.gz helm-charts

sha256sum \
  k3s k3s-airgap-images-amd64.tar.zst k3s-install.sh "${K3S_SELINUX_RPM}" \
  "helm-${HELM_VERSION}-linux-amd64.tar.gz" \
  "ingress-nginx-${INGRESS_NGINX_VERSION}.tgz" ingress-nginx-values.yaml ingress-nginx-images.tar.gz \
  helm-charts.tar.gz my-values.yaml images-plextrac.txt images-ingress-nginx.txt \
  plextrac-images.tar.gz \
  > SHA256SUMS
```

Transfer the files listed in `SHA256SUMS`, plus `SHA256SUMS` itself, to the PlexTrac server
through your approved transfer process.

> If you put the CKEditor license key in `my-values.yaml`, handle the bundle as sensitive. You
> can leave the key empty here and add it on the server in step 2.9.

---

## Part 2: Install on the PlexTrac server

Steps 2.1 to 2.5 need `sudo`; run them from your admin account. From step 2.6 on, work as the
unprivileged `plextrac` user, as in the
[user guide](user-guide.md#step-11--provision-a-kubernetes-cluster).

### 2.1 Unpack and verify the bundle

```bash
id plextrac >/dev/null 2>&1 || sudo useradd -m -s /bin/bash plextrac
sudo mkdir -p /opt/plextrac-airgap
# Copy the bundle files into /opt/plextrac-airgap, then:
sudo chown -R plextrac:plextrac /opt/plextrac-airgap
sudo chmod -R u=rwX,go=rX /opt/plextrac-airgap
sudo chmod 600 /opt/plextrac-airgap/my-values.yaml   # may hold your CKEditor license key
cd /opt/plextrac-airgap
sudo sha256sum -c SHA256SUMS
```

Every line must end in `OK`.

### 2.2 Prepare RHEL 9

**SELinux.** K3s supports SELinux in enforcing mode with the `k3s-selinux` policy:

```bash
getenforce
rpm -q container-selinux selinux-policy-base policycoreutils
sudo dnf install -y --disablerepo='*' ./k3s-selinux-*.el9.noarch.rpm
```

If `rpm -q` reports a package as not installed, install it from your internal RHEL repository or
install media first (for example `sudo dnf install -y container-selinux`). If `getenforce`
prints `Disabled`, you can skip the RPM; leave `selinux: true` out of the K3s configuration in
step 2.4.

> The docker-compose air-gapped procedure ran `setenforce 0`. K3s does not need that. If your
> site runs permissive anyway, also set `SELINUX=permissive` in `/etc/selinux/config`:
> `setenforce 0` on its own does not survive a reboot.

**Firewall.** K3s recommends disabling firewalld. If your security baseline requires it, open
HTTPS for PlexTrac and trust the K3s pod and service networks (rules from the
[K3s requirements](https://docs.k3s.io/installation/requirements)):

```bash
sudo firewall-cmd --permanent --add-port=443/tcp
sudo firewall-cmd --permanent --zone=trusted --add-source=10.42.0.0/16   # pods
sudo firewall-cmd --permanent --zone=trusted --add-source=10.43.0.0/16   # services
sudo firewall-cmd --permanent --add-port=6443/tcp   # only if you will run kubectl from another machine
sudo firewall-cmd --reload
```

**Default route.** K3s needs a default route to detect the node's IP, even one that leads
nowhere:

```bash
ip route show default
```

If this prints nothing, add a route as the [K3s air-gap docs](https://docs.k3s.io/installation/airgap)
describe. These commands do not survive a reboot, so also make the route permanent with your
standard network configuration:

```bash
sudo ip link add dummy0 type dummy
sudo ip link set dummy0 up
sudo ip addr add 203.0.113.254/31 dev dummy0
sudo ip route add default via 203.0.113.255 dev dummy0 metric 1000
```

### 2.3 Stage the image archives

```bash
sudo mkdir -p /var/lib/rancher/k3s/agent/images
sudo cp k3s-airgap-images-amd64.tar.zst ingress-nginx-images.tar.gz plextrac-images.tar.gz \
  /var/lib/rancher/k3s/agent/images/
sudo restorecon -R /var/lib/rancher   # skip if SELinux is disabled
```

Leave the archives there. K3s imports them every time it starts, which also re-pins the images.

### 2.4 Install K3s

```bash
sudo install -m 0755 k3s /usr/local/bin/k3s
sudo restorecon -v /usr/local/bin/k3s   # skip if SELinux is disabled

# Derive a valid node name from the hostname (same rule as the user guide)
NODE_NAME=$(hostname -s | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '-' \
  | sed -E 's/-+/-/g; s/^-+//; s/-+$//' | cut -c1-63 | sed -E 's/-+$//')
[ -z "$NODE_NAME" ] && NODE_NAME=plextrac-node

sudo mkdir -p /etc/rancher/k3s
sudo tee /etc/rancher/k3s/config.yaml >/dev/null <<EOF
node-name: ${NODE_NAME}
write-kubeconfig-mode: "0644"   # lets the plextrac user read the kubeconfig without sudo
disable:
  - traefik                     # PlexTrac uses ingress-nginx
selinux: true                   # remove this line if SELinux is disabled
EOF

sudo env INSTALL_K3S_SKIP_DOWNLOAD=true sh ./k3s-install.sh
```

On first start K3s imports all three archives before it reports ready, so the installer can take
several minutes. To follow it, run `sudo journalctl -u k3s -f` in a second terminal; K3s logs
`Imported N images from ...` for each archive.

Confirm the node is Ready and every bundled image is on it:

```bash
sudo k3s kubectl get nodes

cat images-plextrac.txt images-ingress-nginx.txt | while read -r image; do
  if sudo k3s crictl inspecti "$image" >/dev/null 2>&1 </dev/null; then
    echo "ok       $image"
  else
    echo "MISSING  $image"
  fi
done
```

Every image must print `ok`.

### 2.5 Install Helm

```bash
tar -xzf helm-v*-linux-amd64.tar.gz -C /tmp linux-amd64/helm
sudo install -m 0755 /tmp/linux-amd64/helm /usr/local/bin/helm
helm version
```

### 2.6 Switch to the plextrac user and install ingress-nginx

```bash
sudo su - plextrac
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
echo 'export KUBECONFIG=/etc/rancher/k3s/k3s.yaml' >> ~/.bashrc
cd /opt/plextrac-airgap
tar -xzf helm-charts.tar.gz

helm upgrade --install ingress-nginx ./ingress-nginx-*.tgz \
  --namespace ingress-nginx --create-namespace \
  -f ingress-nginx-values.yaml \
  --wait

kubectl -n ingress-nginx get pods
kubectl -n ingress-nginx get svc ingress-nginx-controller
```

The service's `EXTERNAL-IP` is the server's own IP (K3s ServiceLB).

### 2.7 Create the DNS record

In your internal DNS, point `plextrac.mycompany.com` at the server's IP (the `EXTERNAL-IP`
above). For a quick test without DNS, add an `/etc/hosts` entry on the client machine instead.

### 2.8 Create the namespace and TLS secret

You need a certificate and key for `plextrac.mycompany.com` in PEM files on the server, ideally
issued by your internal CA: `fullchain.pem` (the server certificate followed by any intermediate
certificates) and `privkey.pem`.

For a lab without a CA, generate a self-signed pair instead (browsers will warn):

```bash
openssl req -x509 -newkey rsa:4096 -sha256 -nodes -days 365 \
  -keyout privkey.pem -out fullchain.pem \
  -subj "/CN=plextrac.mycompany.com" \
  -addext "subjectAltName=DNS:plextrac.mycompany.com"
```

Create the namespace and the secret:

```bash
chmod 600 privkey.pem
kubectl create namespace plextrac
kubectl -n plextrac create secret tls plextrac-tls --cert=fullchain.pem --key=privkey.pem
```

The secret name must match `global.ingress.tlsSecretName` in `my-values.yaml`.

### 2.9 Finish the values file

```bash
vi my-values.yaml   # confirm global.ingress.host; set CKEDITOR_SERVER_LICENSE_KEY
```

If you change anything that affects images (an image tag, or enabling an optional component),
rebuild the image lists and archive on the staging host and import it as described in
[Upgrading](#upgrading). Any image that is not on the node fails with `ErrImagePull`.

Re-run the pull-policy check:

```bash
helm template plextrac ./helm-charts/charts/plextrac --namespace plextrac -f my-values.yaml \
  | grep -c 'imagePullPolicy: Always'   # must print 0
```

### 2.10 Install PlexTrac

```bash
helm upgrade --install plextrac ./helm-charts/charts/plextrac \
  --namespace plextrac \
  -f my-values.yaml \
  --wait --timeout 15m
```

`--create-namespace` is not needed: you created the namespace in step 2.8 and
`global.createNamespace` is `false`. The first install runs the database migration inline; watch
it with `kubectl -n plextrac get pods -w` in a second terminal. The startup order and what to
expect are described in [user guide Phase 4](user-guide.md#phase-4--install).

### 2.11 Verify

```bash
kubectl -n plextrac get pods
kubectl -n plextrac get jobs
kubectl get pods -A | grep -E 'ErrImagePull|ImagePullBackOff' || echo "no image pull errors"

INGRESS_IP=$(kubectl -n ingress-nginx get svc ingress-nginx-controller \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
curl -sk --resolve "plextrac.mycompany.com:443:${INGRESS_IP}" \
  https://plextrac.mycompany.com/api/v2/health/full
```

Every pod should be `Running` and Ready, or `Completed` for Jobs, and the health check should
return JSON. `-k` skips certificate verification for this test; use `--cacert <your-ca.pem>`
instead to check the certificate as well.

### 2.12 Sign in

The first `plextracapi` replica to start creates the `global_admin` account and logs a one-time
link for setting its password. Search the logs of all replicas:

```bash
kubectl -n plextrac logs -l app=plextracapi --tail=-1 --prefix | grep 'initial password'
```

Open the link in a browser that can reach `plextrac.mycompany.com`, set the password, and sign in
as `global_admin` (or the `ADMIN_EMAIL` you set). The link expires 24 hours after the account is
created. If nothing is printed or the link has expired, contact PlexTrac support to set the
password.

---

## Upgrading

Build a new bundle for every upgrade. Tags such as `stable` and `latest` are reused across
releases, so the server only gets new application code when you import new images.

> PlexTrac upgrades must follow a supported path (2.x releases one minor version at a time).
> Confirm the path with PlexTrac and repeat this procedure for each step. For a step that is not
> the current `stable` release, set `images.backend.tag` and `images.nginx.tag` in
> `my-values.yaml` to that release's version before you build its bundle.

On the staging host, in `~/plextrac-airgap` with the variables from step 1.1 set:

```bash
git -C helm-charts pull   # or check out the release you are moving to
```

Then re-run steps 1.5 and 1.6. You can skip saving `ingress-nginx-images.tar.gz`: the K3s and
ingress-nginx files do not change. Package and checksum only what you will transfer:

```bash
tar -czf helm-charts.tar.gz helm-charts
sha256sum plextrac-images.tar.gz images-plextrac.txt helm-charts.tar.gz > SHA256SUMS.upgrade
```

If you changed `my-values.yaml` for this upgrade (for example image tags), make the same change
in the server's copy by hand. Don't copy the staging file over it: the server's copy holds your
CKEditor license key.

Transfer the four files into `/opt/plextrac-airgap` on the server. Then, from your admin
account, verify them and replace the image archive. Copying to a temporary name first keeps K3s
from importing a half-written file; the rename makes it import the complete archive while it
runs:

```bash
cd /opt/plextrac-airgap
sudo chown plextrac:plextrac plextrac-images.tar.gz images-plextrac.txt helm-charts.tar.gz SHA256SUMS.upgrade
sudo chmod 644 plextrac-images.tar.gz images-plextrac.txt helm-charts.tar.gz SHA256SUMS.upgrade
sudo sha256sum -c SHA256SUMS.upgrade

sudo cp plextrac-images.tar.gz /var/lib/rancher/k3s/agent/images/plextrac-images.tar.gz.tmp
sudo mv /var/lib/rancher/k3s/agent/images/plextrac-images.tar.gz.tmp \
  /var/lib/rancher/k3s/agent/images/plextrac-images.tar.gz
sudo journalctl -u k3s --since "15 min ago" | grep 'Imported'
```

Then run the image check from step 2.4 against the new `images-plextrac.txt`.

As the `plextrac` user, upgrade and restart:

```bash
cd /opt/plextrac-airgap
rm -rf helm-charts && tar -xzf helm-charts.tar.gz

helm upgrade --install plextrac ./helm-charts/charts/plextrac \
  --namespace plextrac \
  -f my-values.yaml \
  --wait --wait-for-jobs --timeout 15m

kubectl -n plextrac rollout restart deployment
kubectl -n plextrac rollout status deployment/plextracapi --timeout 15m
```

`--wait-for-jobs` holds until the `migrations-and-etl` Job, which already runs the new image,
has migrated the database. The restart is what moves the running pods to the new images: when a
tag is reused, the pod spec does not change, so Helm does not roll the pods by itself. The
restart includes Postgres and MinIO, so API and CKEditor pods may restart once while Postgres
comes back.

> Do not run `crictl rmi --prune` on an air-gapped node. It deletes every image that no running
> container uses, including images that only Jobs use (`bootstrap-minio`, the ingress-nginx
> certificate job). The node cannot pull them back; they return only when K3s restarts and
> re-imports its archives.

---

## Coming from the docker-compose air-gapped procedure

| docker-compose step | K3s equivalent |
|---|---|
| `docker pull` and `docker save` a fixed image list | The list is rendered from your values (1.5), then pulled and saved (1.6) |
| `docker load` on the server | K3s imports archives from `/var/lib/rancher/k3s/agent/images/` (2.3) |
| Install `docker-ce` and the `plextrac` utility | K3s and Helm from the bundle (2.4, 2.5) |
| `plextrac initialize --air-gapped` and `AIRGAPPED=true` in `.env` | Not used. `AIRGAPPED` only told the manager utility to skip image pulls, registry logins, and self-updates. Here, `global.image.pullPolicy: IfNotPresent` does that job |
| `CKEDITOR_SERVER_LICENSE_KEY` in `.env` | `secrets.manual.generatedSecrets.shared.stringData.CKEDITOR_SERVER_LICENSE_KEY` in `my-values.yaml` |
| `CKEDITOR_MIGRATE=true` and `docker-compose.override.yml` for `ckeditor-backend` and `ckeditor-migration` | Built in. The chart deploys `ckeditor-backend`, and the `migrations-and-etl` Job runs the CKEditor environment migration on every install and upgrade |
| `CKEDITOR_ENABLE_METRIC_LOGS=false`, `CKEDITOR_LOG_LEVEL=40` | Not needed for an air gap: they only set CKEditor's log verbosity. The chart uses `true` and `30` and does not expose them as values |
| `setenforce 0` | Keep SELinux enforcing with the `k3s-selinux` policy (2.2) |
| `plextrac configure` and `plextrac install` | `helm upgrade --install` (2.10) |
| `plextrac logs -s plextracapi \| grep password` | `kubectl -n plextrac logs -l app=plextracapi ...` (2.12) |
| Setting the admin password in SQL | Contact PlexTrac support |

---

## Troubleshooting

For anything not specific to the air gap, see the [user guide](user-guide.md#troubleshooting).

### `ErrImagePull` or `ImagePullBackOff`

In an air gap this means the kubelet tried to reach a registry. Check the pod's events, the pull
policy and image it uses, and whether that image is on the node:

```bash
kubectl -n plextrac describe pod <pod> | grep -A10 Events
kubectl -n plextrac get pod <pod> -o jsonpath='{range .spec.initContainers[*]}{.image}{"\t"}{.imagePullPolicy}{"\n"}{end}{range .spec.containers[*]}{.image}{"\t"}{.imagePullPolicy}{"\n"}{end}'
sudo k3s crictl inspecti <image>   # from your admin account
```

- **The policy is `Always`:** the chart is older than 2.29.0, or `global.image.pullPolicy` is not
  set to `IfNotPresent`. Fix `my-values.yaml` and re-run step 2.10.
- **`crictl inspecti` fails:** the image is not on the node because it was not in the bundle (for
  example, you enabled a component after building it). Rebuild the lists and archive on the
  staging host and import it as in [Upgrading](#upgrading).
- **An ingress-nginx image ends in `@sha256:...`:** the digest overrides in
  `ingress-nginx-values.yaml` were not applied. Re-run step 2.6 with `-f ingress-nginx-values.yaml`.

### K3s takes several minutes to start

K3s imports every archive in the images directory before it reports ready, on every start.
Follow it with `sudo journalctl -u k3s -f`.

### K3s fails to start and mentions the node IP or a default route

The server has no default route. See **Default route** in step 2.2.

### SELinux denials

```bash
sudo ausearch -m AVC -ts recent
```

To confirm SELinux is the cause, run `sudo setenforce 0`, retry, then `sudo setenforce 1`, and
send the denials to PlexTrac support.

### Browser certificate warnings

The certificate is not from a CA the browser trusts, or does not name the hostname. Check it:

```bash
kubectl -n plextrac get secret plextrac-tls -o jsonpath='{.data.tls\.crt}' | base64 -d \
  | openssl x509 -noout -subject -issuer -ext subjectAltName
```
