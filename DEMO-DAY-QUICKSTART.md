# 🚀 Demo Day - One-Liner Installation

## Production Deployment Command

For demo day, use this **single command** to deploy the full production setup:

```bash
cd /Users/agiertli/Documents/work/lemonade-stand-assistant/scripts && PROD_MODE=true ./install.sh
```

That's it! This command will:

✅ Create namespace
✅ Configure 7 × g6.4xlarge GPU nodes
✅ Deploy 3× LLaMA (GPU-accelerated)
✅ Deploy 2× HAP Detector (GPU-accelerated)
✅ Deploy 2× Prompt Injection Detector (GPU-accelerated)
✅ Install and validate Grafana dashboards
✅ Configure all networking and monitoring

**Zero manual steps required!**

---

## Installation Time

⏱️ **Total**: ~15-20 minutes

Breakdown:
- GPU nodes provisioning: 5-8 min
- GPU drivers initialization: 3-5 min
- Model pods starting: 5-7 min
- Grafana validation: 1-2 min

---

## Verification

After installation completes, verify everything is ready:

### 1. Check GPU Nodes
```bash
oc get nodes -l beta.kubernetes.io/instance-type=g6.4xlarge
```
**Expected**: 7 nodes, all STATUS: Ready

### 2. Check InferenceServices
```bash
oc get inferenceservice -n lemonade-stand-assistant
```
**Expected**: All READY: True

### 3. Check Running Pods
```bash
oc get pods -n lemonade-stand-assistant | grep -E "llama|hap|injection" | grep Running
```
**Expected**: 7 pods total (3 llama, 2 hap, 2 prompt-injection)

### 4. Get Application URL
```bash
echo "https://$(oc get route lemonade-stand -n lemonade-stand-assistant -o jsonpath='{.spec.host}')"
```

### 5. Get Grafana Dashboard URL
```bash
echo "https://$(oc get route grafana-route -n lemonade-stand-assistant -o jsonpath='{.spec.host}')"
```

---

## If Something Goes Wrong

### GPU Nodes Not Ready
```bash
# Check GPU node status
oc get nodes -l nvidia.com/gpu.present=true

# Check GPU operator pods
oc get pods -n nvidia-gpu-operator
```
**Solution**: Wait 3-5 more minutes for GPU drivers to initialize

### Pods Pending
```bash
# Check why pods are pending
oc describe pod <pod-name> -n lemonade-stand-assistant | grep -A 10 Events
```
**Common causes**: GPU not allocated yet, waiting for GPU drivers

### Grafana Dashboard Empty
```bash
# Run Grafana fix script
cd scripts && ./fix-grafana-dashboard.sh
```

---

## What Gets Deployed

### Infrastructure
- **7 GPU Nodes**: g6.4xlarge (16 vCPU, 64GB RAM, 1 NVIDIA L4 GPU each)
- **Total GPUs**: 7

### Application Components
| Component | Replicas | Resources | GPU |
|-----------|----------|-----------|-----|
| LLaMA 3.2 3B | 3 | 1 CPU, 8Gi RAM | ✅ |
| HAP Detector | 2 | 1 CPU, 4Gi RAM | ✅ |
| Prompt Injection | 2 | 4 CPU, 16Gi RAM | ✅ |
| Grafana | 1 | - | ❌ |
| Support Services | - | - | ❌ |

**Total GPU Usage**: 7/7

---

## Pre-Demo Warm-up

After installation, send test requests to warm up models:

```bash
# Get application URL
APP_URL=$(oc get route lemonade-stand -n lemonade-stand-assistant -o jsonpath='{.spec.host}')

# Send test request
curl -X POST https://$APP_URL/api/chat \
  -H "Content-Type: application/json" \
  -d '{"message": "Hello, test the guardrails"}'
```

This ensures models are loaded and ready for demo.

---

## Quick Reference

### Uninstall
```bash
helm uninstall lemonade-stand-assistant lemonade-grafana -n lemonade-stand-assistant
oc delete project lemonade-stand-assistant
```

### Scale GPU Nodes
```bash
oc scale machineset cluster-9phl9-xkt77-worker-gpu-g6-4xlarge-us-east-2c \
  -n openshift-machine-api --replicas=<number>
```

### View Logs
```bash
# Application logs
oc logs -f deployment/lemonade-stand -n lemonade-stand-assistant

# Model logs
oc logs -f <pod-name> -c kserve-container -n lemonade-stand-assistant
```

### Check Metrics
```bash
# Port-forward to access metrics directly
oc port-forward svc/lemonade-stand 8080:8080 -n lemonade-stand-assistant

# In another terminal
curl http://localhost:8080/metrics
```

---

## Success Checklist ✅

Before the demo starts, verify:

- [ ] All 7 GPU nodes are Ready
- [ ] All 7 pods are Running (3 llama, 2 hap, 2 prompt-injection)
- [ ] All InferenceServices show READY: True
- [ ] Application URL is accessible
- [ ] Grafana dashboard is accessible and showing metrics
- [ ] Test request succeeds and generates guardrail metrics

**If all checked, you're ready to demo! 🎉**

---

## Tips for Demo Success

1. **Run installation the night before** or at least 30 minutes before demo
2. **Keep terminal windows open** with useful commands ready:
   - `oc get pods -n lemonade-stand-assistant -w`
   - `oc logs -f <pod-name> -n lemonade-stand-assistant`
3. **Pre-load Grafana dashboard** in a browser tab
4. **Test all guardrails** once before presenting
5. **Have this quickstart guide open** for quick reference

---

## Emergency Contacts & Resources

- **Installation Guide**: `/INSTALLATION.md`
- **Full Status Report**: `/FINAL-PROD-STATUS.md`
- **Grafana Fix Script**: `/scripts/fix-grafana-dashboard.sh`
- **Production Config**: `/chart/values-prod.yaml`

**Good luck with your demo! 🚀**
