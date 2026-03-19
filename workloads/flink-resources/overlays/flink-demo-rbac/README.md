# Flink Resources - flink-demo-rbac Overlay

This overlay configures Flink resources for the flink-demo-rbac cluster with OAuth authentication.

## CMFRestClass Configuration

The flink-demo-rbac cluster uses namespace-specific CMFRestClass resources:

- **cmfrestclass-shapes.yaml** - CMFRestClass for flink-shapes namespace
- **cmfrestclass-colors.yaml** - CMFRestClass for flink-colors namespace

Both are configured with OAuth authentication pointing to CMF's OAuth-enabled endpoint.

### OAuth Token Management

Each CMFRestClass references a secret named `cmf-oauth-token` that must be created in the respective namespace. This secret should contain:

- OAuth bearer token, or
- Client credentials for obtaining tokens

**Example secret creation:**
```bash
# For shapes namespace
kubectl create secret generic cmf-oauth-token \
  -n flink-shapes \
  --from-literal=bearer-token=<token>

# For colors namespace
kubectl create secret generic cmf-oauth-token \
  -n flink-colors \
  --from-literal=bearer-token=<token>
```

## Authorization Limitations

**Important:** This configuration provides **authentication only** through OAuth.

Full group-based authorization via ConfluentRoleBindings requires:
- MDS (Metadata Service) deployment
- ConfluentRoleBindings created via `confluent iam rbac role-binding create`
- MDS integration with CMF

Without MDS:
- ✅ OAuth authentication works (identity verification)
- ✅ Kubernetes RBAC controls namespace access (implemented in Issue #85)
- ❌ CMF-level RBAC authorization is not enforced

For Kubernetes-level RBAC (namespace isolation, resource permissions), see `workloads/flink-rbac/`.

## Related Resources

- CMF OAuth configuration: `workloads/cmf-operator/overlays/flink-demo-rbac/values.yaml`
- Kubernetes RBAC: `workloads/flink-rbac/`
- Issue #85 - Kubernetes RBAC implementation
- Issue #87 - CMF OAuth configuration (this overlay)
