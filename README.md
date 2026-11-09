<div align="center">

# 🛠️ it-services-aks — TechDesk

### TechDesk IT services helpdesk on Azure AKS — clients, technicians, tickets and assets, built DevOps-style.

**One script** provisions an **Azure Kubernetes Service (AKS)** cluster, a second command
deploys **TechDesk** (PostgreSQL + web dashboard) onto it, and a third tears everything
down — so you can learn managed Kubernetes on Azure in an afternoon, then stop the meter.

![Azure](https://img.shields.io/badge/Microsoft%20Azure-AKS-0078D4?logo=microsoftazure&logoColor=white)
![Kubernetes](https://img.shields.io/badge/Kubernetes-Managed-326CE5?logo=kubernetes&logoColor=white)
![PostgreSQL](https://img.shields.io/badge/Database-PostgreSQL%2016-4169E1?logo=postgresql&logoColor=white)
![Web](https://img.shields.io/badge/Dashboard-nginx-009639?logo=nginx&logoColor=white)
![DevOps](https://img.shields.io/badge/Style-DevOps-success)

</div>

---

## 📖 The story

TechDesk is the helpdesk of a small managed IT services provider (MSP): local
businesses sign up on a plan, their staff raise tickets, technicians pick them up,
and every laptop and printer is tracked as an asset. This repo is that system,
packaged the DevOps way — a PostgreSQL database seeded with the TechDesk schema
(clients, technicians, tickets, ticket updates, assets) and a web dashboard, both
running on a managed Kubernetes cluster on Azure.

## 🌟 What you get

| Feature | What you get |
|---|---|
| 🚀 **One-line bootstrap** | `curl … \| bash` on a fresh Ubuntu VM installs kubectl, helm + Azure CLI, clones the repo, and is ready for `cluster` |
| ☸️ **Cluster provisioning** | `./setup.sh cluster` creates the resource group + AKS cluster and wires up kubectl |
| 🐘 **PostgreSQL app database** | StatefulSet + 5Gi PVC + Secret + schema ConfigMap — the TechDesk tables are created on first start |
| 🖥️ **Web dashboard** | 2-replica nginx Deployment serving the TechDesk dashboard from a ConfigMap, behind a LoadBalancer Service |
| 🧹 **Destroy / cleanup** | `./setup.sh destroy` deletes TechDesk *and* the cluster, behind a type-`yes` confirmation (resource group optional) |
| 🔁 **Same pattern, every business** | Identical layout in the sibling Business Builds repos, so the projects are directly comparable |

## 🏗️ How it fits together

```
   You ──▶ setup.sh cluster ──▶ Azure AKS (resource group techdesk-rg, 2 x Standard_B2s nodes)
                                      │
   You ──▶ setup.sh deploy ──▶ namespace: techdesk
                                      ├── LoadBalancer ──▶ techdesk-web (nginx x2, dashboard from ConfigMap)
                                      └── techdesk-db  (PostgreSQL 16 StatefulSet, 5Gi PVC)
                                             └── schema ConfigMap ──▶ clients / technicians /
                                                 tickets / ticket_updates / assets
```

- **setup.sh** — installs its own prerequisites, checks your Azure login, then provisions / deploys / destroys
- **AKS** — Azure-managed Kubernetes with a VM node pool (2 × `Standard_B2s` by default — small burstable VMs, kind to a learning budget)
- **k8s/** — the whole TechDesk stack: namespace, secret, schema, PVC, StatefulSet, Services, dashboard

## 💸 COST WARNING

> **⚠️ AKS nodes are NOT free — clusters are NOT free, and there is no pause button.**
> The AKS control plane has a free tier, but the node **VMs are billed for every hour
> they run**. Two `Standard_B2s` nodes are only a few dollars a month, but the meter
> never stops on its own — treat this like a hotel room, not a house: check in with
> `./setup.sh cluster`, learn, and check out **the same day** with `./setup.sh destroy`.

## 🚀 Quick start

**From scratch on a fresh Ubuntu VM — one line:**

```bash
curl -fsSL https://raw.githubusercontent.com/UncleD0886475978/it-services-aks/main/setup.sh | bash
```

That bootstrap installs the tools and clones the repo to `~/repos/it-services-aks`. Then:

```bash
cd ~/repos/it-services-aks   # or just stay in your existing checkout

./setup.sh cluster   # create resource group + cluster (5-10 minutes), configure kubectl
./setup.sh deploy    # deploy TechDesk: PostgreSQL + web dashboard
./setup.sh destroy   # delete everything (asks you to type "yes")
```

Already have the repo cloned? `./setup.sh cluster|deploy|destroy` works directly —
the script finds its own checkout and still installs any missing tools.

**See the dashboard** while it's running:

```bash
kubectl -n techdesk get svc techdesk-web     # open http://<EXTERNAL-IP>/
# fallback, no load balancer needed:
kubectl -n techdesk port-forward svc/techdesk-web 8080:80   # http://localhost:8080
kubectl -n techdesk port-forward svc/techdesk-db 5432:5432
psql -h localhost -U techdesk -d techdesk
```

**Make it yours** — every setting is an environment variable:

```bash
CLUSTER_NAME=my-lab REGION=westus2 NODE_COUNT=3 NODE_SIZE=Standard_D2s_v3 ./setup.sh cluster
```

| Variable | Default | Meaning |
|---|---|---|
| `CLUSTER_NAME` | `techdesk` | AKS cluster name |
| `REGION` | `eastus` | Azure location |
| `RESOURCE_GROUP` | `techdesk-rg` | Resource group that holds the cluster |
| `NODE_COUNT` | `2` | Nodes in the default node pool |
| `NODE_SIZE` | `Standard_B2s` | VM size for the nodes |
| `NAMESPACE` | `techdesk` | Namespace TechDesk deploys into |
| `DELETE_RESOURCE_GROUP` | `false` | Set to `true` to delete the resource group too on destroy |

> **Storage note:** the demo uses your cluster's *default* StorageClass — on AKS that's
> Azure Managed Disks (`managed-csi`), which AKS installs by default. If the PVC stays
> `Pending`, check `kubectl get sc`.

## 📁 Project layout

```
it-services-aks/
├── setup.sh                        # cluster | deploy | destroy — installs its own prerequisites
├── k8s/
│   ├── namespace.yaml              # techdesk namespace
│   ├── techdesk-db-secret.example.yaml  # demo credentials (change the password!)
│   ├── techdesk-db-schema.yaml     # ConfigMap: schema.sql (clients, technicians, tickets, updates, assets)
│   ├── techdesk-db-pvc.yaml        # 5Gi persistent storage (default StorageClass)
│   ├── techdesk-db-statefulset.yaml# PostgreSQL 16, 1 replica, schema mounted as init script
│   ├── techdesk-db-service.yaml    # ClusterIP service on 5432
│   ├── techdesk-web-configmap.yaml # the dashboard page (single-file HTML)
│   ├── techdesk-web-deployment.yaml# nginx, 2 replicas
│   └── techdesk-web-service.yaml   # LoadBalancer service on 80
├── .gitignore
└── README.md
```

## 🗺️ Roadmap

- [x] One-script AKS provisioning (resource group + cluster + credentials) + self-installing bootstrap
- [x] TechDesk PostgreSQL schema + dashboard deploy, destroy with confirmation
- [ ] Real TechDesk API service wired to the database (replace the static dashboard)
- [ ] Ticket email notifications and SLA timers
- [ ] TLS + Ingress, real secrets management (Key Vault)
- [ ] Backups (scheduled dumps to Azure Blob Storage)

## 🔗 Sibling repos — Business Builds

One themed business per repo, each with a DevOps/Kubernetes environment:

- 🏥 [zadc-liberia-database](https://github.com/UncleD0886475978/zadc-liberia-database) — ZADC Inc. Liberia — nonprofit database (PostgreSQL)
- 👗 [clothing-store-database](https://github.com/UncleD0886475978/clothing-store-database) — Clothing store database (MySQL)
- 🍔 [fast-food-database](https://github.com/UncleD0886475978/fast-food-database) — Fast-food restaurant database (MongoDB)
- 🏥 [nursing-home-eks](https://github.com/UncleD0886475978/nursing-home-eks) — CareHome nursing home on AWS EKS
- 🛠️ [it-services-aks](https://github.com/UncleD0886475978/it-services-aks) — TechDesk IT services helpdesk on Azure AKS ← **you are here**
- ☁️ [clothing-store-gke](https://github.com/UncleD0886475978/clothing-store-gke) — Clothing store on Google Cloud GKE

---

<div align="center">

**TechDesk — provision it, deploy it, destroy it.** 🛠️

</div>
