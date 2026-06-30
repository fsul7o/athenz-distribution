# ZTS register-contention 負荷試験

`1062 Duplicate entry` エラー（`JDBCCertRecordStoreConnection.insertX509CertRecord` の L223–L262、`athenz/libs/java/server_common/.../JDBCCertRecordStoreConnection.java`）を、kind ベースの Athenz スタック上で再現するための overlay です。

## 概要

失敗パターンは、registerInstanceInformation 時に複数の SIA プロセスや Pod のリトライが、同一の `(provider, instanceId, service)` の組をめぐって競合するというものです。既存実装は INSERT を試み、`1062 Duplicate entry` を catch したら UPDATE にフォールバックする構造になっており、本来不要なはずの 1062 がログに大量に記録されてしまいます。

本試験では、同じ競合状態を cluster 内で再現します。手順は次のとおりです。

1. 専用の Kubernetes namespace `loadtest` と ServiceAccount `zts-contention` を作成します。athenz-identityprovider の OPA ポリシーは、設定の `athenz.domain.prefix/suffix` が空であれば k8s namespace から Athenz domain を導出するため、Athenz サービス `loadtest.zts-contention` にそのまま対応づきます。
2. ZMS に loadtest domain (`loadtest`) と service (`zts-contention`) を登録し、instance provider として `athenz.identityprovider` を紐づけます。
3. `loadtest` namespace に `vegeta-contention` Deployment を立て、`zts-contention` SA で動かします。コンテナのデフォルトマウントである `/var/run/secrets/kubernetes.io/serviceaccount/token` が Kubernetes Service Account Token (SAT) であり、これを OPA が attestation data として検証します。この Pod から送出される 100 並列のリクエストはすべて同じ SAT（＝同じ POD_UID クレーム）を共有するため、ZTS が導出する Athenz instanceId もすべて同一になります。
4. 100 個の CSR を事前生成します。Subject CN・SAN URI・SAN DNS はすべて **同一** で、鍵ペアのみが異なります。
5. Vegeta がこの 100 個のボディを `POST /zts/v1/instance` に送信します。QPS プロファイルは `kubernetes/loadtest/` 配下の他試験と同じ `100 workers / 100 rps / 30s` です。1 件のみが INSERT に成功し、残りはすべて 1062 にぶつかります。

SAT は **attack 実行中に vegeta Pod 内で読み出し**、`sed` で `/tmp/bodies/body-NNN.json` に埋め込みます。ConfigMap への書き出しや cluster 外への持ち出しは行いません。

1062 の計測には MariaDB の **server_audit** プラグインを使用します。本プラグインは、athenz-db Pod 内の `/tmp/server_audit.log` に、実行されたすべての QUERY とその戻り errno を記録します。`,1062$` にマッチする行数が、発生した Duplicate entry の正確な回数であり、フォールバックパスが何回叩かれたかを直接示す値となります。UPSERT（`INSERT ... ON DUPLICATE KEY UPDATE`）にパッチした ZTS イメージで再実行すれば、HTTP の成功率を維持したまま、このカウントがほぼゼロになるはずです。

## ディレクトリ構成

```
contention/
├── Makefile                 # contention 専用の target（deploy/prepare/run/...）
├── README.md                # このファイル
├── kustomize/
│   ├── kustomization.yaml
│   ├── loadtest-namespace.yaml               # loadtest ns + zts-contention SA
│   ├── vegeta-contention-deployment.yaml     # loadtest ns 上の vegeta（SA SAT 利用）
│   (athenz-db の server_audit プラグインは base 側 athenz-db
│    kustomization の audit-configmap.yaml で有効化されているため、
│    この overlay には含めません)
└── scripts/
    ├── setup-zms.sh             # zms-cli で domain / service / template を作成
    ├── generate-csrs.sh         # 鍵 100 個、SAN・CN・instanceId は同一の CSR を生成
    ├── issue-attestation.sh     # vegeta Pod に SAT がマウントされているか確認
    └── build-vegeta-bodies.sh   # body テンプレート（@@SAT@@）と targets.txt を生成
```

各 target はリポジトリルート、`kubernetes/`、`loadtest/`、`contention/` の 4 階層から呼び出せるようになっており、athenz-distribution の「常にリポジトリルートから make を叩く」流儀に合わせています。

| ルートで叩く target                               | 委譲先                                  |
|---------------------------------------------------|-----------------------------------------|
| `deploy-kubernetes-athenz-zts-contention`         | `contention/Makefile: deploy-contention`|
| `prepare-kubernetes-athenz-zts-contention`        | `... prepare-contention`                |
| `sanity-kubernetes-athenz-zts-contention`         | `... sanity-contention`                 |
| `test-kubernetes-athenz-zts-contention`           | `... run-contention`                    |
| `report-kubernetes-athenz-zts-contention`         | `... report-contention`                 |
| `snapshot-kubernetes-athenz-zts-contention-errors`| `... snapshot-mysql-errors`             |
| `reset-kubernetes-athenz-zts-contention`          | `... reset-contention`                  |
| `clean-kubernetes-athenz-zts-contention`          | `... clean-contention`                  |

## 前提条件

以下を実行し、athenz-distribution の kind cluster 上に Athenz スタックを起動します。

```sh
make deploy-kubernetes-in-docker load-docker-images load-kubernetes-images deploy-kubernetes-athenz check-kubernetes-athenz deploy-kubernetes-athenz-identityprovider test-kubernetes-athenz-identityprovider deploy-kubernetes-athenz-loadtest
```

## 使い方（リポジトリルートで実行）

```sh
make deploy-kubernetes-athenz-zts-contention
        # contention 用のリソース（loadtest ns / SA / vegeta）を適用し、
        # base 側 athenz-db で server_audit が ACTIVE であることを確認する。

make prepare-kubernetes-athenz-zts-contention
        # 準備を一括実行するパイプライン：
        #   setup-zms          ZMS に loadtest/zts-contention を作成
        #   generate-csrs      contention/out/ に鍵 100 本と CSR を生成
        #   issue-attestation  contention/out/ に共有 JWT を生成
        #   build-bodies       contention/out/ に body-NNN.json と targets.txt を生成
        #   create-configmaps  vegeta-contention-{bodies,targets} として
        #                      ConfigMap 化し、vegeta を rollout で更新する。

make sanity-kubernetes-athenz-zts-contention
        # 10 workers / 20 rps / 5s。1062 が実際に発火するかの簡易確認。
        # 実行直後に 1062 カウンタも表示する。

make snapshot-kubernetes-athenz-zts-contention-errors
        # 本実行前にベースラインカウンタを取得する。
make test-kubernetes-athenz-zts-contention
        # 100 workers / 100 rps / 30s
make snapshot-kubernetes-athenz-zts-contention-errors
        # ベースラインとの差分が、この run で発生した 1062 の件数。
make report-kubernetes-athenz-zts-contention
        # contention/contention.html（Vegeta の plot）を出力する。
```

### 現状の ZTS と UPSERT パッチ済 ZTS の比較

```sh
# パッチ適用済みの ZTS イメージをビルドする

ATHENZ_REPO_URL=https://github.com/fsul7o/athenz.git \
ATHENZ_REF=fix-incert-x509-cert-record \
make submodule-initialize submodule-update checkout-version

ATHENZ_REPO_URL=https://github.com/fsul7o/athenz.git \
ATHENZ_REF=fix-incert-x509-cert-record \
DOCKER_REGISTRY=localhost:5000/ \
make build-athenz-zts-server
```

```sh
# 現状（未パッチ）の ZTS でベースラインを計測
make reset-kubernetes-athenz-zts-contention
make snapshot-kubernetes-athenz-zts-contention-errors   # T0
make test-kubernetes-athenz-zts-contention
make snapshot-kubernetes-athenz-zts-contention-errors   # T1 → 差分が baseline_1062

# UPSERT パッチ済の ZTS イメージに差し替え
kind load docker-image localhost:5000/athenz-zts-server:latest
kubectl -n athenz set image deployment/athenz-zts-server \
    athenz-zts-server=localhost:5000/athenz-zts-server:latest
kubectl -n athenz rollout status deployment/athenz-zts-server

make reset-kubernetes-athenz-zts-contention
make snapshot-kubernetes-athenz-zts-contention-errors   # T2
make test-kubernetes-athenz-zts-contention
make snapshot-kubernetes-athenz-zts-contention-errors   # T3 → 差分はほぼ 0 になるはず
```
