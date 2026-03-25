# CMF Catalog/Database Relationship Issue

**Date:** 2026-03-25
**Status:** Under Investigation
**Cluster:** flink-demo-rbac
**CMF Version:** 2.2.0

## Problem Statement

Flink SQL Statements fail with error:
```
Execution failed: Catalog 'shapes-catalog' could not be created.
Please check configuration of catalog 'shapes-catalog' and all its databases.
```

Additionally, `confluent flink catalog describe shapes-catalog` shows no databases, despite C3 UI showing `shapes-database` attached to `shapes-catalog`.

## Architecture Overview

**Two-catalog setup with database-level isolation:**
- `shapes-catalog` (KafkaCatalog) → `shapes-database` (KafkaDatabase) → `shapes-env` (Environment)
- `colors-catalog` (KafkaCatalog) → `colors-database` (KafkaDatabase) → `colors-env` (Environment)

**Resource hierarchy:**
- KafkaCatalog: References Schema Registry
- KafkaDatabase: References Kafka cluster, attached to catalog via API path
- CMF Secret: OAuth credentials for Kafka/SR
- EnvironmentSecretMapping: Links secret IDs to secrets
- ComputePool: Dedicated compute resources per environment

## Current State

### What's Working
✅ Catalogs exist in CMF postgres `catalog` table
✅ Databases exist in CMF postgres `catalog_database` table with correct foreign key relationship
✅ C3 UI shows databases attached to catalogs (queries `catalog_database` table directly)
✅ SQL init jobs complete successfully (HTTP 409 - resources already exist)
✅ OAuth authentication working (cmf/cmf-secret credentials)
✅ Kafka super users configured correctly (includes `cmf`)
✅ All ConfigMaps and K8s resources deployed properly

### What's Not Working
❌ Confluent CLI `catalog describe` shows empty databases list
❌ Flink SQL Statements fail to create TableEnvironment
❌ CMF API returns 404 for `/api/cmf/v2/*` paths (tried externally)
❌ Catalog spec in postgres has empty `kafkaClusters` array

## Key Findings

### 1. Postgres Database State
```sql
-- Catalogs exist
SELECT name, type FROM catalog;
      name      | type
----------------+-------
 colors-catalog | KAFKA
 shapes-catalog | KAFKA

-- Databases exist with correct relationship
SELECT name, cat_name, type FROM catalog_database;
      name       |    cat_name    | type
-----------------+----------------+-------
 colors-database | colors-catalog | KAFKA
 shapes-database | shapes-catalog | KAFKA

-- BUT catalog spec has empty kafkaClusters
SELECT spec FROM catalog WHERE name = 'shapes-catalog';
{"srInstance":{...},"kafkaClusters":[]}  -- Empty!
```

### 2. Configuration Reconciliation (March 24-25)

**Breaking change identified:** Commit `b757c89` changed Kafka OAuth from `cmf/cmf-secret` to environment-specific credentials (`sa-shapes-flink/sa-colors-flink`).

**Reverted in:** Commit `fd5e66c`

**Reason for revert:** CMF's catalog registration requires broader Kafka permissions than environment-specific service accounts have. While `sa-shapes-flink` works for FlinkApplications, CMF validation fails during catalog creation.

**Current credentials (working for FlinkApplications, but catalog creation still fails):**
- Kafka OAuth: `cmf/cmf-secret` (in CMF Secrets)
- SR OAuth: `sa-shapes-flink/sa-shapes-flink-secret` (environment-specific, working)

### 3. Database Registration Method

Databases are created via API endpoint:
```bash
POST ${CMF_URL}/catalogs/kafka/shapes-catalog/databases
```

The catalog name in the URL path should automatically link the database to the catalog, but the catalog's `kafkaClusters` array remains empty after creation.

### 4. API Path Confusion

**Internal (from jobs):** `http://cmf-service.operator.svc.cluster.local:80/cmf/api/v1`
**External (attempted):** `http://cmf.flink-demo.confluentdemo.local/api/cmf/v2/*` → 404
**Correct external:** `http://cmf.flink-demo.confluentdemo.local/cmf/api/v1/*` (not tested)

### 5. CLI vs C3 UI Behavior

- **C3 UI:** Queries `catalog_database` table directly → sees relationship
- **Confluent CLI:** Returns catalog spec → sees empty `kafkaClusters` array
- **SQL Statements:** Fails at `DefaultCatalogRegisterer.java:59` with no underlying exception

## Configuration Files

### Critical Files
- `workloads/flink-resources/overlays/flink-demo-rbac/cmf-secret-configmaps.yaml` - OAuth credentials
- `workloads/flink-resources/overlays/flink-demo-rbac/sql-config-configmaps.yaml` - Catalog/Database definitions
- `workloads/flink-resources/overlays/flink-demo-rbac/sql-init-jobs.yaml` - API registration jobs
- `workloads/flink-resources/overlays/flink-demo-rbac/flink-environment-shapes.yaml` - Environment config

### CMF Secret Structure (Current)
```json
{
  "sasl.jaas.config": "org.apache.kafka.common.security.oauthbearer.OAuthBearerLoginModule required clientId='cmf' clientSecret='cmf-secret' scope='profile email';"
}
```

## Mystery: Working Yesterday, Broken Today

**Timeline:**
- **March 24, 4-5:30pm:** Cluster was functional, `SHOW TABLES` worked in C3
- **March 24, 8:13pm:** Last working commit `51621d1`
- **March 25, current:** Same configuration fails after cluster rebuild

**Hypothesis:** The cluster rebuild introduced some state difference that affects catalog registration, despite identical manifests.

## Next Investigation Steps

### 1. API Validation
Test correct CMF API paths with OAuth token:
```bash
# Get OAuth token
TOKEN=$(curl -s -X POST http://keycloak.keycloak.svc.cluster.local:8080/realms/confluent/protocol/openid-connect/token \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=client_credentials" \
  -d "client_id=cmf" \
  -d "client_secret=cmf-secret" | jq -r '.access_token')

# Test API endpoints
curl -H "Authorization: Bearer $TOKEN" http://cmf.flink-demo.confluentdemo.local/cmf/api/v1/catalogs/kafka
curl -H "Authorization: Bearer $TOKEN" http://cmf.flink-demo.confluentdemo.local/cmf/api/v1/catalogs/kafka/shapes-catalog
curl -H "Authorization: Bearer $TOKEN" http://cmf.flink-demo.confluentdemo.local/cmf/api/v1/catalogs/kafka/shapes-catalog/databases
```

### 2. Manual Database Re-registration
Try deleting and recreating via API to see if `kafkaClusters` array populates:
```bash
# Delete database
curl -H "Authorization: Bearer $TOKEN" -X DELETE \
  http://cmf.flink-demo.confluentdemo.local/cmf/api/v1/catalogs/kafka/shapes-catalog/databases/shapes-database

# Recreate database
curl -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" -X POST \
  http://cmf.flink-demo.confluentdemo.local/cmf/api/v1/catalogs/kafka/shapes-catalog/databases \
  -d @/path/to/shapes-database-config.json

# Check catalog spec
kubectl exec -n operator deployment/cmf-postgres -- psql -U cmf -d cmf -c \
  "SELECT spec FROM catalog WHERE name = 'shapes-catalog';"
```

### 3. Check for Schema Version Mismatch
Compare CMF API schema expectations vs actual database schema:
```bash
# Check CMF version
kubectl get deployment -n operator cmf-postgres -o yaml | grep image

# Check flyway migrations
kubectl exec -n operator deployment/cmf-postgres -- psql -U cmf -d cmf -c \
  "SELECT version, description, success FROM flyway_schema_history ORDER BY installed_rank DESC LIMIT 10;"
```

### 4. CMF Logs Deep Dive
Stream CMF logs during SQL statement execution to capture full error:
```bash
kubectl logs -n operator deployment/cmf --follow --tail=100
```
Then execute SQL statement via C3 or CLI and capture complete stack trace.

### 5. Confluent CLI Database Commands
Verify if there's a direct database list command:
```bash
confluent flink database --help
confluent flink statement create shapes-env --sql "SHOW DATABASES" --compute-pool shapes-pool
```

### 6. Compare Working vs Non-Working State
If possible, capture postgres dump from working cluster and compare:
```bash
kubectl exec -n operator deployment/cmf-postgres -- pg_dump -U cmf -d cmf \
  --table=catalog --table=catalog_database --data-only > working-state.sql
```

## Workarounds Attempted

1. ✅ Reverted Kafka OAuth credentials to `cmf/cmf-secret`
2. ✅ Manually deleted CMF secrets via API and recreated via jobs
3. ✅ Restarted CMF deployment
4. ✅ Verified postgres database state
5. ❌ All still fail with same error

## Relevant Documentation

- [CMF CLI Documentation](file:///Users/osowski/git/confluent/docs/docs-cp-flink/clients-api/cli.rst)
- Confluent CLI v4.7.0+ required (installed: v4.50.0)
- Must be logged out of Confluent Cloud for on-prem commands

## Questions to Answer

1. **Why is `kafkaClusters` array empty in catalog spec?**
   - Is this expected behavior?
   - Does CMF populate it lazily on first use?
   - Does it need explicit registration beyond database POST?

2. **Why does C3 show databases but CLI doesn't?**
   - Different query paths confirmed (table vs spec)
   - Is CLI behavior a bug or expected?

3. **What changed between working cluster (yesterday) and current?**
   - Same git commit (`51621d1`)
   - Same manifests
   - Different cluster instance
   - Postgres state? CMF initialization order?

4. **What's the actual error in DefaultCatalogRegisterer.java:59?**
   - No underlying exception in logs
   - Need full stack trace with CMF debug logging

5. **Is this an RBAC/permissions issue?**
   - cmf is in Kafka super users
   - OAuth works for other operations
   - But catalog validation might need specific ACLs?
