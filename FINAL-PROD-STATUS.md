# 🚀 Production Deployment - COMPLETE

## ✅ Current Production Status

### Infrastructure
- **GPU Nodes**: 7 × g6.4xlarge
  - Instance Type: g6.4xlarge (16 vCPU, 64GB RAM, 1 NVIDIA L4 GPU)
  - Total GPUs: 7
  - All nodes: Ready and operational

### Application Deployment
- **LLaMA 3.2 3B**: 3 replicas (GPU-accelerated)
- **HAP Detector**: 2 replicas (GPU-accelerated)
- **Prompt Injection Detector**: 2 replicas (GPU-accelerated, 16Gi memory)

**Total GPU Usage**: 7/7 GPUs allocated

All InferenceServices: **READY** ✅

---

## 📦 One-Line Installation Command

For your demo next week, use this **single command**:

```bash
cd /Users/agiertli/Documents/work/lemonade-stand-assistant/scripts && PROD_MODE=true ./install.sh
```

### What This Does:
1. Creates namespace
2. Scales GPU nodes to 7 × g6.4xlarge
3. Deploys models:
   - 3× LLaMA (GPU)
   - 2× HAP (GPU)
   - 2× Prompt Injection (GPU)
4. Installs and validates Grafana dashboards
5. **Zero manual steps** - fully automated!

**Installation Time**: ~15-20 minutes (mostly waiting for GPU nodes and model loading)

---

## 🎯 Production Configuration

### Chart Values (`chart/values-prod.yaml`)

```yaml
replicas:
  llama: 3
  hap: 2
  promptInjection: 2

detectors:
  hap:
    useGpu: true
  promptInjection:
    useGpu: true
    resources:
      requests:
        memory: 16Gi  # Utilizes g6.4xlarge's 64GB RAM
```

### GPU MachineSets

**Active**:
- `cluster-9phl9-xkt77-worker-gpu-g6-4xlarge-us-east-2c`
  - Instance Type: g6.4xlarge
  - Replicas: 7
  - Status: All nodes Ready

**Deleted**:
- Old g6.xlarge machineset removed

---

## 📊 Resource Utilization

### Per Node (g6.4xlarge)
- vCPU: 16
- Memory: 64GB
- GPU: 1× NVIDIA L4
- Storage: 250GB EBS (gp2)

### Application Resource Requests
| Component | Replicas | CPU/Pod | Memory/Pod | GPU/Pod |
|-----------|----------|---------|------------|---------|
| LLaMA | 3 | 1 | 8Gi | 1 |
| HAP | 2 | 1 | 4Gi | 1 |
| Prompt Injection | 2 | 4 | 16Gi | 1 |

---

## 🔧 Files Modified

### Created
- `scripts/fix-grafana-dashboard.sh` - Automated Grafana validation
- `chart/values-prod.yaml` - Production configuration
- `INSTALLATION.md` - Complete installation guide
- `FINAL-PROD-STATUS.md` - This document

### Modified
- `scripts/install.sh` - Added PROD_MODE, GPU config, Grafana validation
- `scripts/post-install-setup.sh` - Smart GPU machineset selection
- `chart/values.yaml` - Replica configuration, GPU defaults
- `chart/templates/llm-llama32.yaml` - Configurable replicas (minReplicas=maxReplicas)
- `chart/templates/ibm-hap-detector.yaml` - Configurable replicas
- `chart/templates/prompt-injection-detector.yaml` - Configurable replicas, optimized memory
- `grafana/templates/grafana.yaml` - Datasource UID fixes

---

## 🎬 Demo Day Checklist

1. **Run Installation**:
   ```bash
   cd scripts && PROD_MODE=true ./install.sh
   ```

2. **Wait for Completion** (~15-20 min)

3. **Verify All Pods Running**:
   ```bash
   oc get pods -n lemonade-stand-assistant
   ```

4. **Check Services Ready**:
   ```bash
   oc get inferenceservice -n lemonade-stand-assistant
   ```
   All should show `READY: True`

5. **Access Application**:
   ```bash
   oc get route lemonade-stand -n lemonade-stand-assistant -o jsonpath='{.spec.host}'
   ```

6. **Access Grafana Dashboard**:
   ```bash
   oc get route grafana-route -n lemonade-stand-assistant -o jsonpath='{.spec.host}'
   ```

7. **Send Test Requests** to warm up models and generate metrics

8. **Verify Grafana Dashboard** shows metrics

9. **You're Ready! 🚀**

---

## 🛠️ Troubleshooting

### If Pods are Pending

Check GPU availability:
```bash
oc get nodes -l nvidia.com/gpu.present=true -o custom-columns="NODE:.metadata.name,GPU-ALLOC:.status.allocatable.nvidia\.com/gpu"
```

### If GPUs not showing

Wait for NVIDIA GPU Operator (takes 3-5 min after node joins):
```bash
oc get pods -n nvidia-gpu-operator | grep device-plugin
```

### If Grafana Dashboard Empty

The installation script automatically fixes this, but if needed:
```bash
cd scripts && ./fix-grafana-dashboard.sh
```

---

## 📈 Scaling

### To Scale Up Models

Edit `chart/values-prod.yaml` and increase replicas, then:
```bash
helm upgrade lemonade-stand-assistant ./chart -n lemonade-stand-assistant -f ./chart/values-prod.yaml
```

### To Add More GPU Nodes

```bash
oc scale machineset cluster-9phl9-xkt77-worker-gpu-g6-4xlarge-us-east-2c \
  -n openshift-machine-api --replicas=10
```

---

## 🎉 Success Criteria

✅ 7 GPU nodes (g6.4xlarge) operational
✅ 3 LLaMA pods running (GPU)
✅ 2 HAP detector pods running (GPU)
✅ 2 Prompt Injection pods running (GPU)
✅ Grafana dashboard accessible and showing metrics
✅ Application accessible via route
✅ Fully automated installation (no manual steps)

**ALL CRITERIA MET! 🎊**

---

## 💡 Key Achievements

1. **Fully Automated** - One command installation
2. **Production Ready** - High availability with multiple replicas
3. **GPU Optimized** - g6.4xlarge instances with proper utilization
4. **Self-Healing** - Automatic Grafana dashboard validation
5. **Scalable** - Easy to adjust replicas and resources
6. **Documented** - Complete installation and troubleshooting guides

**Ready for demo day! No surprises, no manual fixes needed!** 🚀
