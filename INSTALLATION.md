# Lemonade Stand Assistant - Installation Guide

## Quick Start

### Standard Installation
```bash
cd scripts
./install.sh
```

### Production Installation
```bash
cd scripts
PROD_MODE=true ./install.sh
```

## Installation Modes

### Development Mode (Default)
- **GPU Enabled**: Yes (by default)
- **GPU Replicas**: 3
- **GPU Instance Type**: g5.4xlarge
- **Model Replicas**:
  - LLaMA: 1 replica
  - HAP Detector: 1 replica
  - Prompt Injection Detector: 1 replica

### Production Mode
Activate with: `PROD_MODE=true ./install.sh`

- **GPU Enabled**: Yes
- **GPU Replicas**: 7
- **GPU Instance Type**: g6.4xlarge
- **Model Replicas**:
  - LLaMA: 3 replicas
  - HAP Detector: 2 replicas (GPU-accelerated)
  - Prompt Injection Detector: 2 replicas (GPU-accelerated)

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `PROD_MODE` | `false` | Enable production configuration |
| `NAMESPACE` | `lemonade-stand-assistant` | OpenShift namespace |
| `ENABLE_GPU_DETECTORS` | `true` | Enable GPU for detector models |
| `GPU_REPLICAS` | `3` (dev), `7` (prod) | Number of GPU worker nodes |
| `GPU_INSTANCE_TYPE` | `g5.4xlarge` (dev), `g6.4xlarge` (prod) | AWS instance type for GPU workers |

## Custom Configuration Examples

### Custom GPU Configuration
```bash
GPU_REPLICAS=5 GPU_INSTANCE_TYPE=g5.8xlarge ./install.sh
```

### Disable GPU for Detectors
```bash
ENABLE_GPU_DETECTORS=false ./install.sh
```

### Custom Namespace
```bash
NAMESPACE=my-lemonade-app ./install.sh
```

## What Gets Installed

The installation script performs the following steps:

1. **Create Namespace** - Creates OpenShift project
2. **Configure Cluster** - Sets up GPU nodes, monitoring, TrustyAI, Grafana operator
3. **Install Application** - Deploys the main Helm chart with all models
4. **Install Grafana** - Sets up Grafana dashboards and datasources
5. **Configure Tokens** - Creates service account tokens for Prometheus access
6. **Validate Dashboard** - Automatically fixes and validates Grafana dashboard configuration

## Post-Installation

### Access URLs

After installation completes, you'll see:

```
Application:
  https://lemonade-stand-<namespace>.apps.<cluster-domain>

Grafana Dashboard:
  https://grafana-route-<namespace>.apps.<cluster-domain>
```

### Verify Installation

Check pod status:
```bash
oc get pods -n lemonade-stand-assistant
```

Check InferenceServices:
```bash
oc get inferenceservice -n lemonade-stand-assistant
```

Monitor application logs:
```bash
oc logs -f deployment/lemonade-stand -n lemonade-stand-assistant
```

## Grafana Dashboard

The Grafana dashboard is automatically configured and validated during installation. The script:

1. Creates the dashboard with correct datasource references
2. Configures Prometheus datasource with proper authentication
3. Validates dashboard synchronization
4. Restarts services to ensure proper initialization

**No manual intervention required!**

If you see "No Data" in the dashboard initially, wait a few minutes and send some requests to the application to generate metrics.

## Troubleshooting

### Pods Pending
If model pods are in "Pending" state, check GPU availability:
```bash
oc get nodes -l nvidia.com/gpu.present=true
oc describe pod <pod-name> -n lemonade-stand-assistant
```

### Grafana Dashboard Not Showing
The installation script automatically fixes this. If issues persist:
```bash
cd scripts
./fix-grafana-dashboard.sh
```

### Insufficient GPU Resources
If you see warnings about GPU count:
- Increase `GPU_REPLICAS`
- Verify machinesets: `oc get machineset -n openshift-machine-api`
- Check GPU nodes: `oc get nodes -l nvidia.com/gpu.present=true`

## Uninstallation

```bash
helm uninstall lemonade-stand-assistant lemonade-grafana --namespace lemonade-stand-assistant
oc delete project lemonade-stand-assistant
```

## Advanced: Custom Helm Values

For more granular control, create a custom values file:

```yaml
# my-values.yaml
replicas:
  llama: 5
  hap: 3
  promptInjection: 3

detectors:
  hap:
    useGpu: true
  promptInjection:
    useGpu: true
```

Install with custom values:
```bash
helm install lemonade-stand-assistant ./chart -n lemonade-stand-assistant -f my-values.yaml
```

## Demo Day Preparation

For a reliable demo deployment:

1. **Use Production Mode**:
   ```bash
   PROD_MODE=true ./install.sh
   ```

2. **Pre-warm the models** by sending test requests

3. **Verify all pods are running**:
   ```bash
   oc get pods -n lemonade-stand-assistant
   ```

4. **Test the Grafana dashboard** - ensure metrics are visible

5. **Test the application** - send sample guardrail violations to confirm detection

The installation is now fully automated with no manual steps required!
