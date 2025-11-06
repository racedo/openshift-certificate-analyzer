# Certificate Status Scripts

This directory contains scripts for checking OpenShift certificate status and health.

## Scripts

### 1. `check-certs-table.sh` - Table Format Output
**Purpose**: Displays certificate information in a clean ASCII table format similar to `oc`/`kubectl` outputs.

**Features**:
- Clean columnar display
- Status indicators (✅ OK, ⚠️ EXPIRING, 🔄 ROTATION DUE, ❌ EXPIRED)
- Truncated long values for readability
- CSV export to `certs.csv`

**Usage**:
```bash
./check-certs-table.sh
```

### 2. `check-certs-cli.sh` - Detailed Output
**Purpose**: Provides detailed certificate information with verbose output for troubleshooting.

**Features**:
- Detailed certificate analysis
- All annotations displayed
- 80% rotation calculation
- CSV export to `certs.csv`
- Comprehensive namespace scanning

**Usage**:
```bash
./check-certs-cli.sh
```

### 3. `analyze-tls-registry.sh` - TLS Registry Analysis
**Purpose**: Analyzes comprehensive TLS registry CSV data with detailed breakdowns.

**Features**:
- Complete certificate inventory analysis
- Status indicators (✅ AUTO, 🔄 MANUAL, ⚠️ PARTIAL, ❌ MANUAL)
- Certificate type breakdown
- Refresh period and auto-regenerate analysis
- Top namespaces by certificate count

**Usage**:
```bash
./analyze-tls-registry.sh
```

### 4. `extract-cert-info.sh` - Targeted Certificate Extraction
**Purpose**: Extracts specific certificate information from TLS registry data.

**Features**:
- Filter by certificate type (etcd, api-server, oauth, registry, etc.)
- Filter by management type (refresh-period, auto-regenerate, manual)
- Focused analysis on specific certificate categories
- Clean, targeted output

**Usage**:
```bash
./extract-cert-info.sh [filter]
```

**Available Filters**:
- `refresh-period` - Certificates with refresh periods
- `auto-regenerate` - Certificates with auto-regenerate
- `manual` - Certificates requiring manual management
- `etcd` - ETCD-related certificates
- `api-server` - API server certificates
- `oauth` - OAuth certificates
- `registry` - Image registry certificates
- `monitoring` - Monitoring certificates
- `networking` - Networking certificates
- `ca-bundle` - CA bundle certificates
- `certkeypair` - Certificate key pairs

### 5. `generate-tls-registry.sh` - Live Cluster Registry Generation
**Purpose**: Extracts comprehensive certificate information directly from any OpenShift cluster.

**Features**:
- Scans all namespaces for certificates
- Determines certificate types (CertKeyPair, CA Bundle)
- Identifies refresh periods and auto-regenerate capabilities
- Assigns ownership based on namespace patterns
- Generates timestamped CSV reports

**Usage**:
```bash
./generate-tls-registry.sh
```

### 6. `analyze-generated-registry.sh` - Generated Report Analysis
**Purpose**: Analyzes TLS registry reports generated from live clusters.

**Features**:
- Complete certificate inventory analysis
- Status indicators (✅ AUTO, 🔄 MANUAL, ⚠️ PARTIAL, ❌ MANUAL)
- Certificate type and ownership breakdown
- Top namespaces and ownership distribution
- Comprehensive statistics

**Usage**:
```bash
./analyze-generated-registry.sh [csv_file]
```

### 7. `complete-cert-analysis.sh` - Complete Workflow
**Purpose**: Runs the complete certificate analysis workflow.

**Features**:
- Generates TLS registry report
- Analyzes the generated report
- Runs live certificate status check
- Provides summary and recommendations
- One-command complete analysis

**Usage**:
```bash
./complete-cert-analysis.sh
```

## Output Files

- **`certs.csv`**: CSV export with all certificate data for spreadsheet analysis
- **`tls_registry_report_YYYYMMDD_HHMMSS.csv`**: Comprehensive TLS registry report

## Certificate Coverage

Both scripts check the following critical OpenShift namespaces:
- `openshift-etcd` - ETCD certificates
- `openshift-kube-apiserver` - API server certificates  
- `openshift-authentication` - OAuth certificates
- `openshift-image-registry` - Registry certificates
- `kube-system` - Bootstrap certificates
- `openshift-node` - Kubelet certificates
- `openshift-service-ca` - Service CA certificates
- `openshift-ingress` - Ingress router certificates
- `openshift-monitoring` - Monitoring certificates
- `openshift-console` - Console certificates
- `openshift-ovn-kubernetes` - Network certificates
- `openshift-machine-config-operator` - Machine config certificates

## Requirements

- `oc` command line tool
- Access to OpenShift cluster
- `openssl` for certificate parsing
- `date` command for date calculations

## Status Indicators

- **✅ OK**: Certificate is healthy
- **⚠️ EXPIRING**: Certificate expires within 30 days
- **🔄 ROTATION DUE**: Certificate should be rotated (80% of lifespan)
- **❌ EXPIRED**: Certificate has expired
