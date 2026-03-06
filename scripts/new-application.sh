#!/usr/bin/env bash
#
# new-application.sh - Scaffold new application directory structure and ArgoCD Application
#
# Usage: ./scripts/new-application.sh <app-name> <type> <cluster>
#   or: ./scripts/new-application.sh (interactive mode)
#
# Types: workload, infrastructure
# Example: ./scripts/new-application.sh my-api workload flink-demo
#

set -euo pipefail

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Helper functions
error() {
    echo -e "${RED}ERROR: $1${NC}" >&2
}

success() {
    echo -e "${GREEN}✓ $1${NC}"
}

info() {
    echo -e "${YELLOW}→ $1${NC}"
}

note() {
    echo -e "${BLUE}ℹ $1${NC}"
}

usage() {
    cat <<EOF
Usage: $0 <app-name> <type> <cluster>
   or: $0 (interactive mode)

Scaffold a new application for GitOps deployment.

Arguments:
  app-name  Name of the application (e.g., my-api, payment-service)
  type      Type of application: workload or infrastructure
  cluster   Target cluster name (e.g., flink-demo, prod-us-east)

Types:
  workload        - User-facing applications (uses Kustomize)
                    Creates: namespace, deployment, service, ingress
  infrastructure  - Platform components (uses Helm)
                    Creates: Helm values structure

Example:
  $0 my-api workload flink-demo
  $0 vault infrastructure flink-demo

EOF
}

# Validate application name
validate_app_name() {
    local name="$1"

    # Check format (alphanumeric, hyphens only)
    if ! [[ "$name" =~ ^[a-z0-9][a-z0-9-]*[a-z0-9]$ ]]; then
        error "Application name must contain only lowercase letters, numbers, and hyphens"
        error "Must start and end with alphanumeric character"
        return 1
    fi

    # Check length
    if [ ${#name} -lt 2 ]; then
        error "Application name must be at least 2 characters"
        return 1
    fi

    if [ ${#name} -gt 63 ]; then
        error "Application name must be less than 63 characters"
        return 1
    fi

    return 0
}

# Validate application type
validate_type() {
    local type="$1"

    if [[ ! "$type" =~ ^(workload|infrastructure)$ ]]; then
        error "Type must be 'workload' or 'infrastructure'"
        return 1
    fi

    return 0
}

# Validate cluster exists
validate_cluster() {
    local cluster="$1"

    if [ ! -d "clusters/$cluster" ]; then
        error "Cluster directory not found: clusters/$cluster"
        error "Available clusters:"
        if [ -d "clusters" ]; then
            for dir in clusters/*/; do
                echo "  - $(basename "$dir")"
            done
        fi
        return 1
    fi

    return 0
}

# Check if application already exists
check_app_exists() {
    local app_name="$1"
    local app_type="$2"
    local cluster="$3"

    # Check base directory
    local base_dir="${app_type}s/$app_name"
    if [ -d "$base_dir" ]; then
        error "Application base directory already exists: $base_dir"
        return 1
    fi

    # Check ArgoCD Application manifest
    local app_manifest="clusters/$cluster/${app_type}s/$app_name.yaml"
    if [ -f "$app_manifest" ]; then
        error "ArgoCD Application manifest already exists: $app_manifest"
        return 1
    fi

    return 0
}

# Get repository URL from git config
get_repo_url() {
    local url
    url=$(git config --get remote.origin.url 2>/dev/null || echo "")

    if [ -z "$url" ]; then
        # Default to upstream if no origin
        echo "https://github.com/osowski/confluent-platform-gitops.git"
    else
        # Convert SSH URL to HTTPS if needed
        if [[ "$url" =~ ^git@github.com:(.+)\.git$ ]]; then
            echo "https://github.com/${BASH_REMATCH[1]}.git"
        else
            echo "$url"
        fi
    fi
}

# Create workload application (Kustomize-based)
create_workload() {
    local app_name="$1"
    local cluster="$2"
    local namespace="${3:-$app_name}"
    local port="${4:-8080}"
    local sync_wave="${5:-105}"

    info "Creating workload application: $app_name"

    # Create base directory
    local base_dir="workloads/$app_name/base"
    mkdir -p "$base_dir"
    success "Created $base_dir"

    # Create namespace.yaml
    cat > "$base_dir/namespace.yaml" <<EOF
---
apiVersion: v1
kind: Namespace
metadata:
  name: $namespace
EOF
    success "Created $base_dir/namespace.yaml"

    # Create deployment.yaml
    cat > "$base_dir/deployment.yaml" <<EOF
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $app_name
  namespace: $namespace
  labels:
    app: $app_name
spec:
  replicas: 1
  selector:
    matchLabels:
      app: $app_name
  template:
    metadata:
      labels:
        app: $app_name
    spec:
      containers:
        - name: $app_name
          image: nginx:latest  # TODO: Replace with actual image
          ports:
            - name: http
              containerPort: $port
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              cpu: 200m
              memory: 256Mi
          livenessProbe:
            httpGet:
              path: /
              port: http
            initialDelaySeconds: 30
            periodSeconds: 10
          readinessProbe:
            httpGet:
              path: /
              port: http
            initialDelaySeconds: 5
            periodSeconds: 5
EOF
    success "Created $base_dir/deployment.yaml"

    # Create service.yaml
    cat > "$base_dir/service.yaml" <<EOF
---
apiVersion: v1
kind: Service
metadata:
  name: $app_name
  namespace: $namespace
spec:
  type: ClusterIP
  ports:
    - name: http
      port: $port
      targetPort: http
  selector:
    app: $app_name
EOF
    success "Created $base_dir/service.yaml"

    # Create ingress.yaml
    cat > "$base_dir/ingress.yaml" <<EOF
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: $app_name
  namespace: $namespace
  annotations:
    traefik.ingress.kubernetes.io/router.entrypoints: web
spec:
  rules:
    - host: $app_name.\${CLUSTER_NAME}.\${DOMAIN}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: $app_name
                port:
                  name: http
EOF
    success "Created $base_dir/ingress.yaml"

    # Create base kustomization.yaml
    cat > "$base_dir/kustomization.yaml" <<EOF
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

namespace: $namespace

resources:
  - namespace.yaml
  - deployment.yaml
  - service.yaml
  - ingress.yaml

labels:
  - pairs:
      app.kubernetes.io/name: $app_name
      app.kubernetes.io/managed-by: argocd
EOF
    success "Created $base_dir/kustomization.yaml"

    # Create overlay directory
    local overlay_dir="workloads/$app_name/overlays/$cluster"
    mkdir -p "$overlay_dir"
    success "Created $overlay_dir"

    # Get cluster domain from existing ingress
    local domain="confluentdemo.local"  # Default
    if [ -f "workloads/controlcenter-ingress/overlays/$cluster/ingressroute-patch.yaml" ]; then
        domain=$(grep -oP "Host\(\`[^.]+\.$cluster\.\K[^']+(?='\))" "workloads/controlcenter-ingress/overlays/$cluster/ingressroute-patch.yaml" 2>/dev/null || echo "$domain")
    fi

    # Create ingress-patch.yaml
    cat > "$overlay_dir/ingress-patch.yaml" <<EOF
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: $app_name
  namespace: $namespace
spec:
  rules:
    - host: $app_name.$cluster.$domain
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: $app_name
                port:
                  name: http
EOF
    success "Created $overlay_dir/ingress-patch.yaml"

    # Create overlay kustomization.yaml
    cat > "$overlay_dir/kustomization.yaml" <<EOF
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - ../../base

patches:
  - path: ingress-patch.yaml
    target:
      kind: Ingress
      name: $app_name
EOF
    success "Created $overlay_dir/kustomization.yaml"

    # Create ArgoCD Application
    create_argocd_application "$app_name" "workload" "$cluster" "$namespace" "$sync_wave"
}

# Create infrastructure application (Helm-based)
create_infrastructure() {
    local app_name="$1"
    local cluster="$2"
    local namespace="${3:-$app_name}"
    local sync_wave="${4:-10}"
    local helm_repo="${5:-}"
    local helm_chart="${6:-}"
    local helm_version="${7:-}"

    info "Creating infrastructure application: $app_name"

    # Create base directory
    local base_dir="infrastructure/$app_name/base"
    mkdir -p "$base_dir"
    success "Created $base_dir"

    # Create base values.yaml
    cat > "$base_dir/values.yaml" <<EOF
---
# Base Helm values for $app_name
# These are merged with cluster-specific overlay values

# Add common configuration here
EOF
    success "Created $base_dir/values.yaml"

    # Create overlay directory
    local overlay_dir="infrastructure/$app_name/overlays/$cluster"
    mkdir -p "$overlay_dir"
    success "Created $overlay_dir"

    # Create overlay values.yaml
    cat > "$overlay_dir/values.yaml" <<EOF
---
# Cluster-specific Helm values for $app_name on $cluster
# These override and extend base values

# Add cluster-specific overrides here
EOF
    success "Created $overlay_dir/values.yaml"

    # Create ArgoCD Application
    create_argocd_application "$app_name" "infrastructure" "$cluster" "$namespace" "$sync_wave" "$helm_repo" "$helm_chart" "$helm_version"
}

# Create ArgoCD Application CRD
create_argocd_application() {
    local app_name="$1"
    local app_type="$2"
    local cluster="$3"
    local namespace="$4"
    local sync_wave="$5"
    local helm_repo="${6:-}"
    local helm_chart="${7:-}"
    local helm_version="${8:-}"

    local repo_url
    repo_url=$(get_repo_url)

    # Determine correct directory name (workload -> workloads, infrastructure -> infrastructure)
    local dir_name
    if [ "$app_type" = "workload" ]; then
        dir_name="workloads"
    else
        dir_name="infrastructure"
    fi

    local app_manifest="clusters/$cluster/${dir_name}/$app_name.yaml"
    local project="${dir_name}"

    if [ "$app_type" = "workload" ]; then
        # Kustomize-based application
        cat > "$app_manifest" <<EOF
---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: $app_name
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
  annotations:
    argocd.argoproj.io/sync-wave: "$sync_wave"
spec:
  project: $project
  source:
    repoURL: $repo_url
    targetRevision: HEAD
    path: ${app_type}s/$app_name/overlays/$cluster
  destination:
    server: https://kubernetes.default.svc
    namespace: $namespace
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
    retry:
      limit: 5
      backoff:
        duration: 5s
        factor: 2
        maxDuration: 3m
EOF
    else
        # Helm-based application
        if [ -n "$helm_repo" ] && [ -n "$helm_chart" ]; then
            # Multi-source with specific chart
            cat > "$app_manifest" <<EOF
---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: $app_name
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
  annotations:
    argocd.argoproj.io/sync-wave: "$sync_wave"
spec:
  project: $project
  sources:
    - repoURL: $helm_repo
      targetRevision: ${helm_version:-"*"}  # TODO: Pin to specific version
      chart: $helm_chart
      helm:
        ignoreMissingValueFiles: true
        valueFiles:
          - \$values/infrastructure/$app_name/base/values.yaml
          - \$values/infrastructure/$app_name/overlays/$cluster/values.yaml
    - repoURL: $repo_url
      targetRevision: HEAD
      ref: values
  destination:
    server: https://kubernetes.default.svc
    namespace: $namespace
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true  # Required for CRDs
    retry:
      limit: 5
      backoff:
        duration: 5s
        factor: 2
        maxDuration: 3m
EOF
        else
            # Placeholder for manual Helm configuration
            cat > "$app_manifest" <<EOF
---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: $app_name
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
  annotations:
    argocd.argoproj.io/sync-wave: "$sync_wave"
spec:
  project: $project
  sources:
    # TODO: Add Helm chart repository and configuration
    # - repoURL: <helm-repo-url>
    #   targetRevision: <chart-version>
    #   chart: <chart-name>
    #   helm:
    #     ignoreMissingValueFiles: true
    #     valueFiles:
    #       - \$values/infrastructure/$app_name/base/values.yaml
    #       - \$values/infrastructure/$app_name/overlays/$cluster/values.yaml
    - repoURL: $repo_url
      targetRevision: HEAD
      ref: values
  destination:
    server: https://kubernetes.default.svc
    namespace: $namespace
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
    retry:
      limit: 5
      backoff:
        duration: 5s
        factor: 2
        maxDuration: 3m
EOF
        fi
    fi

    success "Created $app_manifest"
}

# Update cluster kustomization.yaml
update_cluster_kustomization() {
    local app_name="$1"
    local app_type="$2"
    local cluster="$3"

    # Determine correct directory name
    local dir_name
    if [ "$app_type" = "workload" ]; then
        dir_name="workloads"
    else
        dir_name="infrastructure"
    fi

    local kustomization_file="clusters/$cluster/${dir_name}/kustomization.yaml"

    if [ ! -f "$kustomization_file" ]; then
        error "Kustomization file not found: $kustomization_file"
        return 1
    fi

    # Check if already exists
    if grep -q "^[[:space:]]*- $app_name.yaml" "$kustomization_file"; then
        note "Application already listed in $kustomization_file"
        return 0
    fi

    # Add to resources list
    # Insert before the comment or at the end of resources
    if grep -q "^resources:" "$kustomization_file"; then
        # Use awk to add the resource in the resources section
        awk -v app="  - $app_name.yaml" '
        /^resources:/ {
            print
            in_resources = 1
            next
        }
        in_resources && /^[[:space:]]*-/ {
            resources[++n] = $0
            next
        }
        in_resources && !/^[[:space:]]*-/ && !/^[[:space:]]*$/ {
            # End of resources section, print sorted resources
            resources[++n] = app
            asort(resources)
            for (i = 1; i <= n; i++) {
                print resources[i]
            }
            in_resources = 0
            print
            next
        }
        { print }
        END {
            if (in_resources) {
                # Resources section was at the end
                resources[++n] = app
                asort(resources)
                for (i = 1; i <= n; i++) {
                    print resources[i]
                }
            }
        }
        ' "$kustomization_file" > "${kustomization_file}.tmp"
        mv "${kustomization_file}.tmp" "$kustomization_file"
        success "Added $app_name.yaml to $kustomization_file"
    else
        error "No 'resources:' section found in $kustomization_file"
        return 1
    fi
}

# Interactive mode
interactive_mode() {
    echo "=== New Application Setup (Interactive Mode) ==="
    echo ""

    # Get application name
    while true; do
        read -rp "Enter application name (e.g., my-api, vault): " app_name
        if [ -z "$app_name" ]; then
            error "Application name cannot be empty"
            continue
        fi
        if validate_app_name "$app_name"; then
            break
        fi
    done

    # Get application type
    while true; do
        echo ""
        echo "Application type:"
        echo "  1) workload        - User-facing app (Kustomize: deployment, service, ingress)"
        echo "  2) infrastructure  - Platform component (Helm: values files only)"
        read -rp "Select type [1-2]: " type_choice
        case "$type_choice" in
            1|workload)
                app_type="workload"
                break
                ;;
            2|infrastructure)
                app_type="infrastructure"
                break
                ;;
            *)
                error "Invalid choice. Enter 1 or 2"
                ;;
        esac
    done

    # Get cluster
    echo ""
    echo "Available clusters:"
    if [ -d "clusters" ]; then
        local clusters=()
        local i=1
        for dir in clusters/*/; do
            local cluster_name=$(basename "$dir")
            clusters+=("$cluster_name")
            echo "  $i) $cluster_name"
            ((i++))
        done

        while true; do
            read -rp "Select cluster [1-${#clusters[@]}]: " cluster_choice
            if [[ "$cluster_choice" =~ ^[0-9]+$ ]] && [ "$cluster_choice" -ge 1 ] && [ "$cluster_choice" -le "${#clusters[@]}" ]; then
                cluster="${clusters[$((cluster_choice-1))]}"
                break
            else
                error "Invalid choice. Enter number between 1 and ${#clusters[@]}"
            fi
        done
    else
        error "No clusters directory found"
        exit 1
    fi

    # Check if application exists
    if ! check_app_exists "$app_name" "$app_type" "$cluster"; then
        exit 1
    fi

    # Get namespace
    echo ""
    read -rp "Enter namespace (default: $app_name): " namespace
    namespace="${namespace:-$app_name}"

    # Get sync wave
    echo ""
    echo "Sync wave (controls deployment order):"
    echo "  Infrastructure: 10-50 (lower = earlier)"
    echo "  Workloads: 105+ (higher = later)"
    if [ "$app_type" = "workload" ]; then
        default_wave="105"
        read -rp "Enter sync wave (default: 105): " sync_wave
    else
        default_wave="10"
        read -rp "Enter sync wave (default: 10): " sync_wave
    fi
    sync_wave="${sync_wave:-$default_wave}"

    # Type-specific prompts
    if [ "$app_type" = "workload" ]; then
        echo ""
        read -rp "Enter container port (default: 8080): " port
        port="${port:-8080}"
    else
        # Infrastructure - Helm details
        echo ""
        read -rp "Do you have Helm chart details? [y/N]: " has_helm
        if [[ "$has_helm" =~ ^[Yy]$ ]]; then
            read -rp "Enter Helm repository URL (e.g., https://charts.example.com): " helm_repo
            read -rp "Enter Helm chart name: " helm_chart
            read -rp "Enter chart version (or * for latest): " helm_version
            helm_version="${helm_version:-*}"
        else
            helm_repo=""
            helm_chart=""
            helm_version=""
        fi
    fi

    # Summary
    echo ""
    echo "Summary:"
    echo "  Application: $app_name"
    echo "  Type:        $app_type"
    echo "  Cluster:     $cluster"
    echo "  Namespace:   $namespace"
    echo "  Sync Wave:   $sync_wave"
    if [ "$app_type" = "workload" ]; then
        echo "  Port:        $port"
    else
        if [ -n "$helm_repo" ]; then
            echo "  Helm Repo:   $helm_repo"
            echo "  Helm Chart:  $helm_chart"
            echo "  Version:     $helm_version"
        fi
    fi
    echo ""
    read -rp "Create application? [y/N] " confirm

    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        info "Cancelled"
        exit 0
    fi

    # Set variables for main function
    APP_NAME="$app_name"
    APP_TYPE="$app_type"
    CLUSTER="$cluster"
    NAMESPACE="$namespace"
    SYNC_WAVE="$sync_wave"
    if [ "$app_type" = "workload" ]; then
        PORT="$port"
    else
        HELM_REPO="${helm_repo:-}"
        HELM_CHART="${helm_chart:-}"
        HELM_VERSION="${helm_version:-}"
    fi
}

# Main function
main() {
    # Check if running from repository root (handles both normal repos and worktrees)
    if [ ! -e ".git" ] || [ ! -d "clusters" ]; then
        error "Must run from repository root"
        exit 1
    fi

    # Parse arguments or run interactive mode
    if [ $# -eq 0 ]; then
        interactive_mode
    elif [ $# -eq 3 ]; then
        APP_NAME="$1"
        APP_TYPE="$2"
        CLUSTER="$3"

        # Validate inputs
        if ! validate_app_name "$APP_NAME"; then
            exit 1
        fi

        if ! validate_type "$APP_TYPE"; then
            exit 1
        fi

        if ! validate_cluster "$CLUSTER"; then
            exit 1
        fi

        if ! check_app_exists "$APP_NAME" "$APP_TYPE" "$CLUSTER"; then
            exit 1
        fi

        # Set defaults for non-interactive mode
        NAMESPACE="$APP_NAME"
        if [ "$APP_TYPE" = "workload" ]; then
            SYNC_WAVE="105"
            PORT="8080"
        else
            SYNC_WAVE="10"
            HELM_REPO=""
            HELM_CHART=""
            HELM_VERSION=""
        fi
    elif [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
        usage
        exit 0
    else
        error "Invalid arguments"
        echo ""
        usage
        exit 1
    fi

    info "Creating $APP_TYPE application: $APP_NAME for cluster $CLUSTER"
    echo ""

    # Determine directory names
    local app_dir cluster_dir
    if [ "$APP_TYPE" = "workload" ]; then
        app_dir="workloads"
        cluster_dir="workloads"
    else
        app_dir="infrastructure"
        cluster_dir="infrastructure"
    fi

    # Create application structure based on type
    if [ "$APP_TYPE" = "workload" ]; then
        create_workload "$APP_NAME" "$CLUSTER" "$NAMESPACE" "${PORT:-8080}" "$SYNC_WAVE"
    else
        create_infrastructure "$APP_NAME" "$CLUSTER" "$NAMESPACE" "$SYNC_WAVE" "${HELM_REPO:-}" "${HELM_CHART:-}" "${HELM_VERSION:-}"
    fi

    # Update cluster kustomization
    if ! update_cluster_kustomization "$APP_NAME" "$APP_TYPE" "$CLUSTER"; then
        error "Failed to update cluster kustomization"
        note "You may need to manually add '$APP_NAME.yaml' to clusters/$CLUSTER/${cluster_dir}/kustomization.yaml"
    fi

    echo ""
    success "Application $APP_NAME created successfully!"
    echo ""
    echo "Generated files:"
    if [ "$APP_TYPE" = "workload" ]; then
        echo "  - ${app_dir}/$APP_NAME/base/ (namespace, deployment, service, ingress)"
        echo "  - ${app_dir}/$APP_NAME/overlays/$CLUSTER/ (cluster-specific patches)"
    else
        echo "  - ${app_dir}/$APP_NAME/base/values.yaml (base Helm values)"
        echo "  - ${app_dir}/$APP_NAME/overlays/$CLUSTER/values.yaml (cluster values)"
    fi
    echo "  - clusters/$CLUSTER/${cluster_dir}/$APP_NAME.yaml (ArgoCD Application)"
    echo "  - clusters/$CLUSTER/${cluster_dir}/kustomization.yaml (updated)"
    echo ""
    echo "Next steps:"
    if [ "$APP_TYPE" = "workload" ]; then
        echo "  1. Update ${app_dir}/$APP_NAME/base/deployment.yaml with your container image"
        echo "  2. Adjust resource requests/limits as needed"
        echo "  3. Configure health check endpoints (liveness/readiness probes)"
        echo "  4. Review and customize ingress configuration"
    else
        echo "  1. Add Helm chart details to clusters/$CLUSTER/${cluster_dir}/$APP_NAME.yaml"
        echo "  2. Configure values in ${app_dir}/$APP_NAME/base/values.yaml"
        echo "  3. Add cluster-specific overrides to ${app_dir}/$APP_NAME/overlays/$CLUSTER/values.yaml"
    fi
    if [ "$APP_TYPE" = "workload" ]; then
        echo "  5. Test locally:"
        echo "     kubectl kustomize ${app_dir}/$APP_NAME/overlays/$CLUSTER/"
        echo "  6. Commit changes:"
        echo "     git add ${app_dir}/$APP_NAME/ clusters/$CLUSTER/${cluster_dir}/"
        echo "     git commit -m 'Add $APP_NAME $APP_TYPE application'"
        echo "  7. Push and let ArgoCD sync automatically"
    else
        echo "  4. Test locally:"
        echo "     helm template $APP_NAME <chart> -f ${app_dir}/$APP_NAME/base/values.yaml"
        echo "  5. Commit changes:"
        echo "     git add ${app_dir}/$APP_NAME/ clusters/$CLUSTER/${cluster_dir}/"
        echo "     git commit -m 'Add $APP_NAME $APP_TYPE application'"
        echo "  6. Push and let ArgoCD sync automatically"
    fi
    echo ""
    echo "For more details, see: docs/adding-applications.md"
}

main "$@"
