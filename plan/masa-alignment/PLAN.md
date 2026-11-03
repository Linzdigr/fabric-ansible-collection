# Plan d'alignement du training sur l'environnement cible MASA (dev / prod)

> **Langue** — ce document est rédigé en français car il décrit un contexte
> d'intégration spécifique au MASA, non destiné à l'upstream. Les lots qui ont
> vocation à remonter dans `hyperledger-labs/fabric-ansible-collection`
> (sectorisation par namespace, NetworkPolicies, profils d'environnement) devront
> être re-rédigés en anglais au moment de la contribution — cf. §11.
>
> **Documents liés** — [PRE-ANALYSIS.md](../move-ingress/PRE-ANALYSIS.md) et
> [MIGRATION-PLAN.md](../move-ingress/MIGRATION-PLAN.md) (migration ingress-nginx →
> Gateway API). Le présent plan s'appuie sur leurs conventions (scénarios A/B/C,
> variable `ingress_type`, drapeaux `expose_*`) et ne les redéfinit pas.

---

## 1. Objectif et périmètre

Rendre le training (`tutorial/`) exécutable **sans modification structurelle** sur
les clusters dev et prod du MASA, et permettre de tester dès aujourd'hui, en local,
dans des conditions représentatives — avant confirmation des accès Rancher.

Trois résultats attendus :

1. **Fidélité** — un environnement local qui reproduit les contraintes MASA
   (CNI qui applique réellement les NetworkPolicies, PSA, quotas, RBAC restreint,
   registre miroir, kubeconfig de type Rancher).
2. **Sectorisation** — un namespace Kubernetes par organisation Fabric, avec un
   modèle de flux *default-deny* et des autorisations explicites.
3. **Portabilité** — un même jeu de playbooks paramétré par profil
   (`local` / `masa-dev` / `masa-prod`) via un inventaire Ansible, sans fichiers
   de variables édités à la main.

**Hors périmètre** : la migration Gateway API elle-même (couverte par
`plan/move-ingress/`), le durcissement des images Fabric amont, la production de
certificats par la PKI interne MASA (traité ici comme un prérequis paramétrable).

---

## 2. État des lieux — ce que le training suppose aujourd'hui

Constats issus de l'audit du dépôt (branche `move-ingress`) :

| # | Constat | Emplacement | Impact MASA |
|---|---------|-------------|-------------|
| C1 | **Namespace unique** : tous les composants Fabric (CA, peers, orderers) sont créés par le *deployer* de la console, dans le namespace de la console. Aucun module n'expose de paramètre `namespace`. | [consoles.py](../../plugins/module_utils/consoles.py) (API `/ak/api/v3/`), [k8s/create.yml](../../roles/fabric_console/tasks/k8s/create.yml) | **Bloquant** pour la sectorisation par organisation |
| C2 | **Opérateur mono-namespace** : `WATCH_NAMESPACE` est valorisé depuis `metadata.namespace`. | [hlf-operator-manager.yaml.j2:67](../../roles/fabric_operator_crds/templates/k8s/manager/hlf-operator-manager.yaml.j2#L67) | Un opérateur par namespace, ou passage en multi-namespace (spike S1) |
| C3 | **Aucune NetworkPolicy** dans le dépôt. Le seul levier existant (`IBPOPERATOR_CONSOLE_APPLYNETWORKPOLICY`) n'est câblé que sur la variante OpenShift de `hlfsupport_console`. | [operator.yml.j2:101](../../roles/hlfsupport_console/templates/openshift/operator.yml.j2#L101) | Flux totalement ouverts — non conforme prod |
| C4 | **PSA `baseline`** codé en dur à la création du namespace. | [k8s/create.yml:31](../../roles/fabric_operator_crds/tasks/k8s/create.yml#L31) | À confronter à un `restricted` probable côté MASA |
| C5 | **Droits cluster-admin implicites** : création de CRD, `ClusterRole`, `ClusterRoleBinding`. | [k8s/create.yml](../../roles/fabric_operator_crds/tasks/k8s/create.yml), [hlf-operator-clusterrolebinding.yaml.j2](../../roles/fabric_operator_crds/templates/k8s/rbac/hlf-operator-clusterrolebinding.yaml.j2) | Peu probable d'être accordé sur un cluster mutualisé |
| C6 | **Images tirées directement d'Internet** (ghcr.io, docker.io, registry.access.redhat.com), y compris dans un dict imbriqué `console_versions` où les registres sont figés. | [fabric_console/defaults/main.yml](../../roles/fabric_console/defaults/main.yml), [fabric_operator_crds/defaults/main.yml](../../roles/fabric_operator_crds/defaults/main.yml) | Incompatible avec un cluster sans egress Internet |
| C7 | **StorageClass en dur** (`standard`, `default`). | mêmes fichiers | Nom de SC MASA différent |
| C8 | **Secrets en clair** : `api_secret`, `ca_admin_enrollment_secret: adminpw`, mots de passe d'organisation. | [tutorial/org1-vars.yml](../../tutorial/org1-vars.yml) et consorts | Interdit en prod |
| C9 | **Identités enrôlées écrites dans `playbook_dir`** (`wallet: "{{ playbook_dir }}"`), avec clés privées. Seul `tutorial/.gitignore` (`*.json`) protège du commit. | [endorsing_organization/defaults/main.yml](../../roles/endorsing_organization/defaults/main.yml) | Fuite de matériel cryptographique |
| C10 | **Domaine et TLS de développement** : `localho.st`, `nip.io`, certificats auto-générés. | [kind_with_nginx.sh](../../.github/scripts/kind_with_nginx.sh) | Domaine interne + PKI MASA à injecter |
| C11 | **`shell: kubectl`** utilisé pour l'attente de l'opérateur. | [k8s/create.yml:55](../../roles/fabric_operator_crds/tasks/k8s/create.yml#L55) | Dépend d'un binaire + `KUBECONFIG` hors du modèle `kubernetes.core` |
| C12 | **KIND avec kindnet** : le CNI par défaut de KIND **n'applique pas** les NetworkPolicies. | [kind_with_nginx.sh](../../.github/scripts/kind_with_nginx.sh) | Toute politique écrite serait silencieusement inopérante en CI/local |
| C13 | **Aucun quota / LimitRange** ; les `resources` des composants sont optionnels. | rôles `*_organization` | Rejet à l'admission si le namespace MASA porte un `ResourceQuota` |
| C14 | Variables de connexion dupliquées dans 4 fichiers plats, réécrites par `yq` en CI. | [run-tutorial-tests.sh](../../.github/scripts/run-tutorial-tests.sh) | Pas de séparation dev/prod ; pas de vault |

C12 est le constat le plus insidieux : sans changer de CNI, on peut écrire des
NetworkPolicies, les voir « appliquées » par l'API, et n'avoir **aucune** isolation
réelle. Tout le lot sécurité en dépend.

---

## 3. Hypothèses sur la cible MASA

Non confirmées — à valider (checklist §12). Elles sont explicitées ici pour que le
plan reste exploitable même si certaines s'avèrent fausses ; chaque hypothèse
fausse impacte un lot identifié.

| Réf | Hypothèse | Lot impacté si fausse |
|-----|-----------|----------------------|
| H1 | Clusters RKE2 pilotés par Rancher, un cluster dev et un cluster prod distincts | W2, W7 |
| H2 | CNI Canal/Calico — NetworkPolicy standard appliquée | W4 (si Cilium : envisager `CiliumNetworkPolicy` pour les règles L7) |
| H3 | Accès via kubeconfig Rancher (proxy `/k8s/clusters/c-xxxxx`), token utilisateur ou compte de service | W2 |
| H4 | Pas de `cluster-admin` pour l'équipe applicative ; les CRD/ClusterRole sont posés par l'équipe socle | W1, W3 |
| H5 | Egress Internet fermé ; registre miroir interne (Harbor/Nexus/Artifactory) | W5 |
| H6 | Namespaces rattachés à un *Project* Rancher, potentiellement avec « Project Network Isolation » | W4 |
| H7 | PSA `restricted` visé en prod, `baseline` toléré en dev | W6 |
| H8 | ingress-nginx fourni par le socle ; Gateway API **non** installé à ce jour | W8 |
| H9 | Ansible exécuté depuis un bastion / runner hors cluster → **scénario B** au sens de la PRE-ANALYSIS | W8, drapeaux `expose_*` |

---

## 4. Décision structurante : topologie de namespaces

C1 et C2 rendent la sectorisation impossible « par variable ». Trois topologies
sont envisageables ; il faut trancher avant d'écrire la moindre NetworkPolicy.

### 4.1 Option A — un tenant complet par organisation *(recommandée)*

Chaque organisation Fabric possède son namespace, **son** opérateur et **sa**
console. C'est le seul modèle réalisable sans patcher l'amont, et c'est aussi le
modèle qui correspond à la cible fonctionnelle (chaque organisation MASA est une
entité autonome, avec sa propre console d'exploitation).

```
hlf-platform-gw     Gateway / ingress partagé (socle)
hlf-orderer         opérateur + console + IBPOrderer         (Ordering Org)
hlf-org1            opérateur + console + IBPCA + IBPPeer    (Org1)
hlf-org2            opérateur + console + IBPCA + IBPPeer    (Org2)
```

- **Pour** : aucun patch amont ; isolation RBAC naturelle ; `expose_*` réglable par
  organisation ; correspond au scénario C de la PRE-ANALYSIS si les organisations
  migrent plus tard vers leurs propres clusters.
- **Contre** : N consoles (coût mémoire ≈ 1 Go par console + CouchDB) ; N `api_endpoint`
  dans l'inventaire ; les playbooks `03/04/07/08/13/14/16-*` (export/import) deviennent
  **obligatoires** — c'est le mode `-i` de `build_network.sh`, aujourd'hui optionnel.

### 4.2 Option B — namespace unique, isolation par cluster

Statu quo, avec dev et prod séparés au niveau cluster.

- **Pour** : zéro changement ; chemin nominal supporté par l'amont.
- **Contre** : aucune sectorisation intra-cluster ; ne répond pas à la demande.

### 4.3 Option C — plateforme mutualisée + namespaces organisation

Un namespace `hlf-platform` (opérateur + console unique) pilotant des composants
déployés dans `hlf-org1`, `hlf-org2`, `hlf-orderer`.

- **Pour** : une seule console, sectorisation réelle des charges Fabric.
- **Contre** : nécessite (a) un opérateur multi-namespace (`WATCH_NAMESPACE` en liste,
  cache multi-namespace) et (b) un *deployer* capable de créer les CR hors de son
  propre namespace. (b) n'est pas exposé par l'API console actuelle → **patch amont
  obligatoire**. Non retenu à court terme.

### 4.4 Recommandation

Retenir **l'option A**, et l'instruire par le spike **S1** : mesurer l'empreinte
réelle de N consoles et vérifier si `WATCH_NAMESPACE` accepte une liste (ce qui
ouvrirait l'option C à moyen terme, en contribution amont).

Conséquence directe sur le training : `build_network.sh` et `join_network.sh`
doivent basculer en mode import/export par défaut sur les profils MASA — le chemin
`-i` devient le chemin nominal.

---

## 5. Modèle de flux — sectorisation réseau

### 5.1 Étiquetage des namespaces (prérequis à toute politique)

Aucune politique ne peut désigner un namespace sans étiquette. À poser à la création :

```yaml
labels:
  hlf.masa/tenant: org1            # org1 | org2 | orderer | platform
  hlf.masa/role: fabric-org        # fabric-org | fabric-orderer | gateway
  hlf.masa/network: mainnet        # cloisonne plusieurs réseaux Fabric d'un même cluster
  pod-security.kubernetes.io/enforce: "{{ psa_level }}"
  kubernetes.io/metadata.name: hlf-org1   # posée automatiquement par K8s ≥ 1.21
```

`kubernetes.io/metadata.name` sert de garde-fou : si l'étiquetage métier est perdu
(recréation via Rancher), les politiques restent adressables par nom.

### 5.2 Matrice de flux cible

Sens : ligne = source, colonne = destination. Tout ce qui n'est pas listé est refusé.

| Source → Destination | Port(s) | Justification |
|---|---|---|
| Tous → CoreDNS (`kube-system`) | 53/UDP, 53/TCP | Résolution — sans cette règle, un default-deny egress casse tout |
| Peer → Orderer (`hlf-orderer`) | 7050/TCP | Soumission de transactions, `channel fetch/update` |
| Peer ↔ Peer (inter-organisations) | 7051/TCP | Gossip + endorsement |
| Peer → sa CA (intra-namespace) | 7054/TCP | Enrôlement / ré-enrôlement |
| Orderer → sa CA (intra-namespace) | 7054/TCP | Idem |
| Peer → chaincode pods | 7052/TCP (peer) ; port CCaaS (chaincode) | Builder k8s du `k8s-fabric-peer` — **à confirmer, cf. R3** |
| Console/deployer → composants du même tenant | 7050, 7051, 7054, 9443 | Cycle de vie + sondes `/healthz` |
| Opérateur → API server | 443/TCP (ipBlock du plan de contrôle) | Réconciliation des CR |
| Gateway (`hlf-platform-gw`) → composants exposés | selon `expose_*` : 443, 7050, 7051 | Terminaison/passthrough — cf. MIGRATION-PLAN §2.2 |
| Machine de contrôle Ansible (hors cluster) → Gateway | 443, 7050, 7051 | Scénario B (H9) |
| Prometheus (`cattle-monitoring-system`) → composants | 9443/TCP | Scraping des endpoints d'opérations |
| Composants → registre d'images | 443/TCP | Via kubelet, **hors NetworkPolicy** — ne pas essayer de le couvrir ici |

Points à ne pas manquer :

- **CouchDB** est un conteneur du *même pod* que le peer dans le modèle opérateur —
  trafic loopback, aucune règle nécessaire. À confirmer sur la version d'opérateur
  retenue (R3).
- **L'egress vers l'API server** ne peut pas se décrire par `namespaceSelector` :
  l'API server n'est pas un pod du cluster (ou l'est via `kubernetes.default` avec
  une ClusterIP hors plage pods). Utiliser un `ipBlock` paramétré par profil.
- **Project Network Isolation Rancher** (H6) : si activée, elle injecte ses propres
  NetworkPolicies au niveau du *Project*. Deux namespaces de Projects différents
  ne communiqueront pas, quelles que soient nos règles. → placer tous les namespaces
  HLF dans **le même Project** Rancher, ou obtenir la désactivation.

### 5.3 Catalogue de politiques à produire

Un rôle Ansible dédié (`hlf_namespace`, cf. W3) génère par namespace :

| Politique | Type | Contenu |
|---|---|---|
| `default-deny-all` | Ingress + Egress | Base de tout le modèle |
| `allow-dns` | Egress | vers `kube-system`, pods CoreDNS, 53 |
| `allow-same-namespace` | Ingress + Egress | `podSelector: {}` intra-namespace |
| `allow-from-gateway` | Ingress | depuis `hlf.masa/role: gateway`, ports selon `expose_*` |
| `allow-fabric-mesh` | Ingress + Egress | depuis/vers `hlf.masa/network: <réseau>`, ports 7050/7051 |
| `allow-ca-from-mesh` | Ingress | 7054 depuis les namespaces du même réseau — **uniquement si `expose_ca`** |
| `allow-apiserver-egress` | Egress | `ipBlock` du plan de contrôle, 443 |
| `allow-monitoring` | Ingress | depuis le namespace de supervision, 9443 |

Chaque politique est conditionnée par une variable, de sorte qu'un profil `local`
puisse démarrer en `default-deny` désactivé puis l'activer, pour isoler les
régressions au moment du diagnostic.

---

## 6. Alignement Rancher et Ansible

### 6.1 Accès au cluster

- Récupérer depuis Rancher un kubeconfig par cluster, écrit dans un chemin par profil
  (`_cfg/masa-dev.kubeconfig`). Le serveur pointe vers le proxy Rancher
  (`https://rancher.<domaine>/k8s/clusters/c-xxxxx`), pas vers l'API server direct.
- Conséquence sur C11 : la tâche `shell: kubectl rollout status` ne verra le bon
  cluster que si `KUBECONFIG` est propagé. La remplacer par
  `kubernetes.core.k8s_info` sur `status.conditions` du Deployment (même approche
  que celle déjà recommandée pour la console dans MIGRATION-PLAN §5.5) — cela
  supprime la dépendance au binaire `kubectl` et respecte le `kubeconfig` passé aux
  modules.
- Prévoir un compte de service Rancher dédié à l'automatisation, avec un rôle
  *namespace-admin* sur les namespaces HLF — et **valider tôt** que le playbook
  tenant fonctionne avec ces seuls droits (W1).

### 6.2 Séparation prérequis socle / tenant

Reprend et généralise la décision déjà actée dans MIGRATION-PLAN §1.1
(« le contrôleur d'ingress est un prérequis, pas une tâche du rôle ») :

| Playbook | Exécutant | Droits | Contenu |
|---|---|---|---|
| `00-cluster-prereqs.yml` | Équipe socle MASA | cluster-admin | CRD Fabric, `ClusterRole`/`ClusterRoleBinding` de l'opérateur, contrôleur d'ingress (ou GatewayClass), StorageClass, Project Rancher |
| `01-namespaces.yml` | Automatisation | namespace-admin + création de namespace | Namespaces, étiquettes, NetworkPolicies, ResourceQuota, LimitRange, `imagePullSecret`, RBAC |
| `02..n` (training) | Automatisation | namespace-admin | Playbooks `tutorial/` existants |

Ce découpage est la condition pour que le training tourne sur MASA sans
`cluster-admin` (H4). Il documente aussi précisément ce qu'il faut **demander** à
l'équipe socle — livrable utile avant même l'obtention des accès.

### 6.3 Inventaire et variables

Remplacer les fichiers plats (C14) par une structure d'inventaire :

```
inventories/
  local/        hosts.yml  group_vars/all/{cluster,images,network,psa}.yml
  masa-dev/     hosts.yml  group_vars/all/…  vault.yml
  masa-prod/    hosts.yml  group_vars/all/…  vault.yml
  common/       group_vars/all/{fabric_versions,topology}.yml
```

- Les secrets (C8) passent en `ansible-vault`, avec un `.gitignore` sur les fichiers
  déchiffrés.
- `wallet` (C9) pointe vers un répertoire hors dépôt, paramétré par profil, et le
  `.gitignore` racine est étendu (`*.json` dans `tutorial/` ne couvre pas un wallet
  déplacé).
- `build_network.sh` / `join_network.sh` acceptent `-e <profil>` et propagent
  `-i <inventaire>` à chaque `ansible-playbook`.

---

## 7. Images et stockage

- Introduire `image_registry_prefix` (défaut : vide → comportement actuel) appliqué
  à **toutes** les références, y compris les registres figés dans `console_versions`
  (C6) — ce dict imbriqué doit être construit par template, pas recopié.
- Produire un **inventaire exhaustif des images** (nom + tag + digest) à faire
  mirroir côté MASA : opérateur, console, deployer, init (`ubi-minimal`), couchdb,
  grpc-web, fabric-ca, fabric-peer / k8s-fabric-peer, fabric-orderer, fabric-tools.
  Ce fichier est un livrable en soi, à transmettre à l'équipe socle avant les accès.
- `imagePullSecret` créé par `01-namespaces.yml` dans chaque namespace.
- `storage_class` / `console_storage_class` remontés au niveau profil (C7) ; vérifier
  le mode d'accès requis (RWO suffit pour CA/peer/orderer ; la CA HA — cf.
  `examples/create-ha-ca/` — impose une base partagée, à arbitrer).

---

## 8. Environnement local haute-fidélité

C'est le cœur de la demande : pouvoir tester **avant** les accès.

Nouveau script `.github/scripts/kind_masa_like.sh`, dérivé de `kind_with_nginx.sh`,
qui produit un cluster reproduisant les contraintes MASA :

1. **CNI appliquant les NetworkPolicies** — désactiver le CNI par défaut
   (`disableDefaultCNI: true`) et installer Calico. Corrige C12, sans quoi tout le
   lot sécurité est non testable. Alternative si MASA confirme Cilium : installer
   Cilium à la place, pour tester le même moteur de politiques.
2. **Version de Kubernetes alignée** sur celle du cluster dev MASA (aujourd'hui
   `kindest/node:v1.25.3`, très probablement obsolète vis-à-vis de la cible).
3. **PSA** : labels `restricted` sur les namespaces du profil `hardened`.
4. **Quotas** : `ResourceQuota` + `LimitRange` calibrés sur le dimensionnement MASA,
   pour faire échouer localement ce qui échouerait là-bas (C13).
5. **RBAC restreint** : créer un ServiceAccount « comme Rancher » (namespace-admin,
   sans droits cluster) et générer un kubeconfig à partir de son token ; les
   playbooks tenant s'exécutent avec celui-ci. C'est le moyen le plus fiable de
   découvrir les manques de droits **avant** de les découvrir sur MASA.
6. **Registre miroir** : réutiliser le registre local déjà présent dans
   `kind_with_nginx.sh` comme pull-through, et exécuter au moins un run avec
   `image_registry_prefix` pointant dessus, egress Internet coupé par NetworkPolicy.
7. **Domaine et TLS** : domaine local factice (`hlf.masa.test`) résolu via l'override
   CoreDNS existant, et certificat émis par une CA locale injectée dans l'image
   Ansible — pour valider la chaîne de confiance côté `fabric-sdk-py` (C10).

Le tout piloté par un profil : `just up local`, `just up local-hardened`.

---

## 9. Refactor du training

| Élément | Aujourd'hui | Cible |
|---|---|---|
| `tutorial/*-vars.yml` | 4 fichiers plats, réécrits par `yq` | `group_vars` par profil + vault |
| Topologie | 1 namespace implicite | 1 namespace par organisation (option A) |
| Import/export | Optionnel (`-i`) | Nominal sur profils MASA |
| Prérequis | Implicites | `00-cluster-prereqs.yml` + `01-namespaces.yml` |
| Attente opérateur | `shell: kubectl` | `kubernetes.core.k8s_info` |
| Wallet | `playbook_dir` | Répertoire hors dépôt, par profil |
| Scripts | Pas de paramètre d'environnement | `-e <profil>` |

Contrainte forte : **ne pas casser le chemin existant**. Tous les nouveaux
comportements sont conditionnés par des variables dont les valeurs par défaut
reproduisent le comportement actuel — même principe que `ingress_type: nginx` dans
MIGRATION-PLAN §3.

---

## 10. CI — extension de la matrice

La matrice prévue par MIGRATION-PLAN (`nginx` | `gateway-api`) reçoit un second axe :

| Axe | Valeurs |
|---|---|
| `ingress_type` | `nginx`, `gateway-api` |
| `profile` | `permissive` (actuel), `hardened` (Calico + default-deny + PSA restricted + quotas + RBAC restreint + namespace par organisation) |

Le job `hardened` est celui qui protège contre les régressions d'isolation. Ajouter
un test négatif explicite : vérifier qu'un pod témoin d'un namespace non autorisé
**ne peut pas** joindre le port 7051 d'un peer. Sans ce test, une politique
inopérante (C12) passerait inaperçue.

---

## 11. Lots de travail

| # | Lot | Dépend de | Effort | Contribution amont ? |
|---|-----|-----------|--------|---------------------|
| W0 | Spikes S1–S3 (§12) | — | S | — |
| W1 | Découpage prérequis socle / tenant + suppression de la dépendance `kubectl` (C5, C11) | — | M | Oui |
| W2 | Inventaire Ansible multi-profils, vault, wallet hors dépôt (C8, C9, C14) | — | M | Partiel |
| W3 | Rôle `hlf_namespace` : namespaces, étiquettes, quotas, LimitRange, RBAC, pull secret | W2 | M | Oui |
| W4 | NetworkPolicies (§5.3) + test négatif | W3, S2 | L | Oui |
| W5 | `image_registry_prefix` + inventaire des images (C6) | — | M | Oui |
| W6 | PSA `restricted` : audit des `securityContext` des composants (C4) | S3 | M | Oui (amont opérateur) |
| W7 | Environnement local haute-fidélité `kind_masa_like.sh` (§8) | W3, W4 | L | Oui |
| W8 | Topologie option A dans le training : N consoles, import/export nominal (§4.1, §9) | W1, W3 | L | Non (spécifique) |
| W9 | Matrice CI `permissive` / `hardened` (§10) | W7, W8 | M | Oui |
| W10 | Documentation : `docs/source/tutorials/masa-deployment.rst` + demande à l'équipe socle | tous | M | Partiel |

Chemin critique : **W0 → W1 → W3 → W4 → W7**. C'est ce chemin qui rend le test
« en conditions proches » possible sans attendre les accès.

Séquencement conseillé avant obtention des accès : W0, W1, W3, W5, W7 — ils ne
dépendent d'aucune information MASA non confirmée. W4 et W6 dépendent de S2/S3.

---

## 12. À confirmer auprès du MASA / spikes

### 12.1 Questions bloquantes (à poser dès le premier échange)

1. Distribution et version exacte de Kubernetes (dev et prod), version de Rancher.
2. CNI et **application effective** des NetworkPolicies (Canal, Calico, Cilium ?).
3. Modèle d'accès : kubeconfig proxy Rancher ? compte de service ? durée de vie du token ?
4. Droits accordés : `cluster-admin` possible pour la pose des CRD, ou passage par
   l'équipe socle ? Qui pose les `ClusterRole` ?
5. Politique de namespaces : nommage imposé, rattachement à un *Project* Rancher,
   « Project Network Isolation » activée ?
6. Niveau PSA appliqué (`baseline` / `restricted`) et exceptions possibles.
7. Registre d'images interne : URL, procédure de mirroring, egress Internet autorisé ou non.
8. StorageClasses disponibles, modes d'accès, provisionnement dynamique.
9. **ingress-nginx est-il déployé avec `--enable-ssl-passthrough` ?** Condition
   *sine qua non* du chemin nginx pour Fabric (PRE-ANALYSIS §2.3). Gateway API
   disponible ou non.
10. Domaine interne pour la console et les endpoints Fabric ; PKI émettrice ;
    résolution DNS (wildcard possible ?).
11. Supervision : Prometheus du socle, scraping des endpoints `9443` attendu ?
12. Depuis où s'exécute Ansible : bastion, runner GitLab/AWX, dans ou hors cluster ?
    (détermine scénario A vs B, donc les drapeaux `expose_*`).

### 12.2 Spikes techniques (réalisables sans accès)

| Réf | Spike | Question tranchée |
|---|---|---|
| **S1** | Déployer 2 consoles + 2 opérateurs dans 2 namespaces sur KIND ; mesurer CPU/RAM/PV. Tester `WATCH_NAMESPACE` avec une liste de namespaces. | Option A viable ? Option C ouverte à terme ? |
| **S2** | KIND + Calico, `default-deny` complet, dérouler le training ; recenser *tous* les flux réellement nécessaires. | Matrice §5.2 exacte ou incomplète |
| **S3** | Forcer PSA `restricted` sur le namespace, observer les rejets d'admission (opérateur, console, init containers, CouchDB, chaincode). | `restricted` atteignable, ou exception à négocier |
| **S4** | Exécuter le training avec un kubeconfig de ServiceAccount *namespace-admin* uniquement. | Périmètre exact des droits à demander |
| **S5** | Run complet avec `image_registry_prefix` et egress Internet coupé. | Exhaustivité de l'inventaire d'images |

Les spikes S2, S3 et S4 produisent chacun un livrable directement transmissible à
l'équipe socle MASA (matrice de flux, liste d'exceptions PSA, liste de droits RBAC),
ce qui accélère la phase d'ouverture des accès.

---

## 13. Critères d'acceptation

1. Le training se déroule de bout en bout sur `local` **et** `local-hardened`, avec
   trois namespaces (org1, org2, orderer) et un `default-deny` actif dans chacun.
2. Le test négatif de la CI échoue si l'une des NetworkPolicies est retirée.
3. Aucun playbook du parcours tenant n'exige de droits cluster ; les prérequis
   cluster sont isolés dans `00-cluster-prereqs.yml`.
4. Un run complet réussit sans egress Internet, images depuis le registre miroir.
5. Aucun secret ni clé privée en clair dans le dépôt ; `git status` propre après un run.
6. Le passage `local` → `masa-dev` se fait par changement d'inventaire seul, sans
   modification de playbook.
7. Le comportement historique (namespace unique, nginx, KIND) reste inchangé avec
   les valeurs par défaut.

---

## 14. Risques

| Réf | Risque | Impact | Atténuation |
|---|---|---|---|
| R1 | N consoles (option A) dépassent le quota du namespace ou du cluster MASA | Élevé | S1 mesure l'empreinte ; arbitrer une console mutualisée en dev, sectorisée en prod |
| R2 | PSA `restricted` incompatible avec les images Fabric amont | Élevé | S3 ; négocier une exception documentée, ou contribuer les correctifs amont |
| R3 | Le builder chaincode k8s crée des pods dont les flux ne sont pas couverts par la matrice §5.2 | Moyen | S2 doit inclure le déploiement de chaincode (`deploy_smart_contract.sh`), pas seulement la construction du réseau |
| R4 | « Project Network Isolation » Rancher supplante nos politiques | Moyen | Question §12.1 n°5 ; regrouper les namespaces dans un même Project |
| R5 | Absence de `ssl-passthrough` sur l'ingress MASA | Élevé | Question §12.1 n°9 posée en priorité ; repli sur Gateway API (plan move-ingress) |
| R6 | Divergence croissante avec l'amont si les lots ne sont pas contribués | Moyen | Marquage « contribution amont » dans le tableau §11 ; re-rédaction anglaise au fil de l'eau |
| R7 | Version de Kubernetes MASA très supérieure à `v1.25.3` (KIND actuel) : API supprimées | Moyen | Aligner le nœud KIND dès la réponse à la question §12.1 n°1 |
