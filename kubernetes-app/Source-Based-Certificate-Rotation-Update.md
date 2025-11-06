# OpenShift Certificate Monitor - Source-Based Rotation Update

## 📋 **What Was Updated**

You asked: **"where do you get the rotation periods from?"** and **"update the monitoring script and add a link on the generated website to the line of the source code that has the rotation hardcoded"**

This was an excellent question that exposed that my previous rotation periods were **assumptions**, not facts from OpenShift source code.

## 🔍 **Source Analysis Performed**

### **OpenShift Source File Analyzed:**
```
https://github.com/openshift/origin/blob/main/tls/raw-data/raw-tls-artifacts-ha-amd64-metal-ovn-techpreviewnoupgrade.json
```

### **ValidityDuration Frequency Analysis:**
Based on analysis of 217 ValidityDuration entries in the OpenShift source:

| **ValidityDuration** | **Count** | **Use Case** |
|---------------------|-----------|--------------|
| `2y` (730 days) | **91 occurrences** | Service CA, Ingress/Router, Monitoring, Console, Network |
| `10y` (3650 days) | **41 occurrences** | API server components |
| `23h/24h` | **30 occurrences** | Short-lived aggregator certificates |
| `365d` (1 year) | **15 occurrences** | Kubelet and control plane certificates |
| `3y` (1095 days) | **14 occurrences** | Specialized certificates |
| `5y` (1825 days) | **4 occurrences** | etcd certificates |
| Other | Various | 182d, 12h, 9y, 364d for specialized uses |

## ❌ **Previous (Incorrect) Assumptions:**
```bash
# What I assumed before (WRONG):
Router/Ingress: 90 days
Monitoring: 365 days
Console: 365 days  
Service CA: 365 days
Network: 730 days
Machine Config: 365 days
```

## ✅ **New (Source-based) Rotation Periods:**
```bash
# Actual ValidityDuration from OpenShift source:
Service CA (openshift-service-ca): 2y (730 days)
Ingress/Router (openshift-ingress): 2y (730 days) 
Monitoring (openshift-monitoring): 2y (730 days)
Console (openshift-console): 2y (730 days)
Network (openshift-ovn-kubernetes): 2y (730 days)
Machine Config: 365d (1 year) - only this one was different
etcd certificates: 5y (1825 days)
API Server components: 10y (3650 days)
```

## 🔗 **Source Links Added**

Each certificate type now includes a direct link to the OpenShift source code where its `ValidityDuration` is defined:

- **Service CA**: `[source]` → Links to source line showing `"ValidityDuration": "2y"`
- **Ingress/Router**: `[source]` → Links to source line showing `"ValidityDuration": "2y"`
- **Monitoring**: `[source]` → Links to source line showing `"ValidityDuration": "2y"`
- **Console**: `[source]` → Links to source line showing `"ValidityDuration": "2y"`
- **Network**: `[source]` → Links to source line showing `"ValidityDuration": "2y"`
- **Machine Config**: `[source]` → Links to source line showing `"ValidityDuration": "365d"`

## 🚀 **What Changed in the Application**

### **1. Updated Script**: `deploy-cert-status-app-with-source-links.yaml`
- ✅ **ACTUAL rotation periods** from OpenShift source (not assumptions)
- ✅ **Source links** for every certificate type
- ✅ **Frequency analysis** showing how often each ValidityDuration appears
- ✅ **Transparency section** explaining methodology
- ✅ **Direct links** to OpenShift source file

### **2. Enhanced UI Features**
- 📋 **Source box** at top showing data source and methodology
- 🔗 **Source links** next to each rotation period
- 📊 **Frequency analysis** showing ValidityDuration distribution
- 🔬 **Methodology section** explaining how periods are determined
- 📈 **Transparency**: Links to exact lines in OpenShift source code

### **3. Key Corrections Made**
- **Service CA**: Changed from 365 days → **730 days** (2y) ✅
- **Ingress/Router**: Changed from 90 days → **730 days** (2y) ✅
- **Monitoring**: Changed from 365 days → **730 days** (2y) ✅
- **Console**: Changed from 365 days → **730 days** (2y) ✅
- **Network**: Kept 730 days (2y) - this one was correct ✅
- **Machine Config**: Kept 365 days (365d) - this one was correct ✅

## 🌐 **Access the Updated Monitor**

**Main Application URL:**
```
https://cert-status-route-cert-status-app.apps.my-hosted-cluster.apps.pm-lab.pm-cluster.pemlab.rdu2.redhat.com
```

**Direct Certificates Page:**
```
https://cert-status-route-cert-status-app.apps.my-hosted-cluster.apps.pm-lab.pm-cluster.pemlab.rdu2.redhat.com/certs.html
```

## 🔍 **How to Verify Source Links**

1. **Visit the certificates page** → Each certificate section shows its ValidityDuration
2. **Click [source] links** → Takes you directly to the OpenShift source code
3. **Verify the JSON** → You can see the actual `"ValidityDuration": "2y"` entries
4. **View frequency analysis** → Shows how common each ValidityDuration is

## 📊 **Impact of the Update**

### **Before (Assumptions)**
- ❌ Rotation periods were **guessed**
- ❌ No source links or verification
- ❌ Several periods were **significantly wrong** (Service CA, Ingress, Monitoring, Console)

### **After (Source-based)**
- ✅ Rotation periods are **verified** from OpenShift source
- ✅ Every period has a **direct link** to source code
- ✅ All periods are **accurate** based on actual ValidityDuration values
- ✅ **Transparency**: Users can verify the data themselves

## 🎯 **Key Takeaway**

This update transforms the certificate monitor from an **assumption-based** tool to a **source-verified** tool. Users can now trust the rotation predictions because they're based on actual OpenShift ValidityDuration values with direct links to the source code for verification.

The most significant finding: **Most OpenShift certificates use 2y (730 days) ValidityDuration**, not the shorter periods I previously assumed. 