#!/usr/bin/env python3
"""
OpenShift Certificate Discovery Web App
Uses the logic from get-all-cluster-certificates.sh to discover and display
all certificates in the cluster with management status and CA categories.
"""

import os
import base64
import subprocess
import json
import re
import time
import logging
import sqlite3
from datetime import datetime, timezone, timedelta
from threading import Thread, Lock
from flask import Flask, render_template_string, jsonify
from kubernetes import client, config
from kubernetes.client.rest import ApiException
from cryptography import x509
from cryptography.hazmat.backends import default_backend
from cryptography.hazmat.primitives import hashes

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

app = Flask(__name__)

# Database path (on persistent volume)
DB_PATH = '/data/certificates.db'

# Try to load in-cluster config, fallback to kubeconfig
try:
    config.load_incluster_config()
    logger.info("Loaded in-cluster Kubernetes config")
except:
    try:
        config.load_kube_config()
        logger.info("Loaded kubeconfig from file")
    except:
        logger.warning("Failed to load Kubernetes config")
        pass

# Certificate cache with thread-safe access
class CertificateCache:
    """Thread-safe cache for certificate data with background refresh."""

    def __init__(self, refresh_interval=300):
        self.data = None
        self.cluster_name = 'unknown-cluster'
        self.last_update = None
        self.lock = Lock()
        self.refresh_interval = refresh_interval
        self.refresh_thread = None
        logger.info(f"Initialized CertificateCache with {refresh_interval}s refresh interval")

    def start_background_refresh(self):
        """Start background thread to refresh certificate data."""
        def refresh_loop():
            while True:
                try:
                    logger.info("Starting certificate discovery...")
                    start_time = time.time()
                    certificates = discover_certificates()
                    cluster_name = self._get_cluster_name()

                    with self.lock:
                        self.data = certificates
                        self.cluster_name = cluster_name
                        self.last_update = datetime.now(timezone.utc)

                    elapsed = time.time() - start_time
                    logger.info(f"Certificate discovery completed: {len(certificates)} certificates found in {elapsed:.2f}s")

                    # Save to database if available
                    save_discovery_to_db(certificates, cluster_name, elapsed)
                except Exception as e:
                    logger.error(f"Error in background refresh: {e}", exc_info=True)

                time.sleep(self.refresh_interval)

        self.refresh_thread = Thread(target=refresh_loop, daemon=True)
        self.refresh_thread.start()
        logger.info("Background refresh thread started")

    def _get_cluster_name(self):
        """Get cluster name from infrastructure object."""
        try:
            custom_api = client.CustomObjectsApi()
            infra = custom_api.get_cluster_custom_object('config.openshift.io', 'v1', 'infrastructures', 'cluster')
            return infra.get('status', {}).get('infrastructureName', 'unknown-cluster')
        except Exception as e:
            logger.warning(f"Error getting cluster info: {e}")
            return 'unknown-cluster'

    def get_data(self):
        """Get cached certificate data. Triggers immediate refresh if no data available."""
        with self.lock:
            if self.data is None:
                logger.info("Cache empty, triggering immediate refresh")
                # Release lock during discovery to avoid blocking
                pass

        # If cache is empty, do an immediate refresh (outside lock)
        if self.data is None:
            try:
                logger.info("Performing initial certificate discovery...")
                start_time = time.time()
                certificates = discover_certificates()
                cluster_name = self._get_cluster_name()

                with self.lock:
                    self.data = certificates
                    self.cluster_name = cluster_name
                    self.last_update = datetime.now(timezone.utc)

                elapsed = time.time() - start_time
                logger.info(f"Initial discovery completed: {len(certificates)} certificates in {elapsed:.2f}s")

                # Save to database if available
                save_discovery_to_db(certificates, cluster_name, elapsed)
            except Exception as e:
                logger.error(f"Error during initial refresh: {e}", exc_info=True)
                return [], 'unknown-cluster', None

        with self.lock:
            return self.data, self.cluster_name, self.last_update

# Global cache instance (will be started after functions are defined)
cert_cache = CertificateCache(refresh_interval=14400)  # 4 hours

def init_database():
    """Initialize SQLite database with certificate tracking tables."""
    try:
        # Check if /data directory exists (PV mounted)
        data_dir = os.path.dirname(DB_PATH)
        if not os.path.exists(data_dir):
            logger.warning(f"Data directory {data_dir} does not exist - PV may not be mounted. Database will not be available.")
            return False

        conn = sqlite3.connect(DB_PATH)
        cursor = conn.cursor()

        # Create certificate_discoveries table
        cursor.execute('''
            CREATE TABLE IF NOT EXISTS certificate_discoveries (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                timestamp DATETIME DEFAULT CURRENT_TIMESTAMP,
                cluster_name TEXT,
                total_certificates INTEGER,
                platform_managed INTEGER,
                user_managed INTEGER,
                auto_rotated INTEGER,
                discovery_duration_seconds REAL
            )
        ''')

        # Create certificates table
        cursor.execute('''
            CREATE TABLE IF NOT EXISTS certificates (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                discovery_id INTEGER,
                namespace TEXT,
                name TEXT,
                resource_type TEXT,
                fingerprint TEXT,
                issuer TEXT,
                expiry TEXT,
                validity_years INTEGER,
                managed_status TEXT,
                ca_category TEXT,
                FOREIGN KEY (discovery_id) REFERENCES certificate_discoveries(id)
            )
        ''')

        # Create indexes for fast queries
        cursor.execute('CREATE INDEX IF NOT EXISTS idx_fingerprint ON certificates(fingerprint)')
        cursor.execute('CREATE INDEX IF NOT EXISTS idx_discovery_id ON certificates(discovery_id)')
        cursor.execute('CREATE INDEX IF NOT EXISTS idx_expiry ON certificates(expiry)')

        conn.commit()
        conn.close()

        logger.info(f"Database initialized successfully at {DB_PATH}")
        return True
    except Exception as e:
        logger.error(f"Error initializing database: {e}", exc_info=True)
        return False

def cleanup_old_discoveries(retention_days=30):
    """Delete discovery runs older than retention_days."""
    try:
        if not os.path.exists(DB_PATH):
            return

        conn = sqlite3.connect(DB_PATH)
        cursor = conn.cursor()

        # Calculate cutoff date
        cutoff_date = datetime.now(timezone.utc) - timedelta(days=retention_days)
        cutoff_str = cutoff_date.strftime('%Y-%m-%d %H:%M:%S')

        # Get IDs of discoveries to delete
        cursor.execute('''
            SELECT id FROM certificate_discoveries
            WHERE timestamp < ?
        ''', (cutoff_str,))

        old_discovery_ids = [row[0] for row in cursor.fetchall()]

        if old_discovery_ids:
            # Delete associated certificates first (foreign key constraint)
            cursor.execute(f'''
                DELETE FROM certificates
                WHERE discovery_id IN ({','.join('?' * len(old_discovery_ids))})
            ''', old_discovery_ids)

            deleted_certs = cursor.rowcount

            # Delete old discoveries
            cursor.execute(f'''
                DELETE FROM certificate_discoveries
                WHERE id IN ({','.join('?' * len(old_discovery_ids))})
            ''', old_discovery_ids)

            deleted_discoveries = cursor.rowcount

            conn.commit()
            logger.info(f"Cleaned up {deleted_discoveries} old discoveries (>{retention_days} days) and {deleted_certs} certificate records")

        conn.close()
    except Exception as e:
        logger.error(f"Error cleaning up old discoveries: {e}", exc_info=True)

def save_discovery_to_db(certificates, cluster_name, duration):
    """Save discovery results to database."""
    try:
        # Check if database is available
        if not os.path.exists(DB_PATH):
            logger.debug("Database not available, skipping save")
            return None

        conn = sqlite3.connect(DB_PATH)
        cursor = conn.cursor()

        # Calculate statistics
        total = len(certificates)
        platform_managed = len([c for c in certificates if 'Platform-Managed' in c.get('managed_status', '')])
        user_managed = len([c for c in certificates if 'User-Managed' in c.get('managed_status', '')])
        auto_rotated = len([c for c in certificates if 'Auto-Rotated' in c.get('managed_status', '')])

        # Insert discovery run
        cursor.execute('''
            INSERT INTO certificate_discoveries
            (cluster_name, total_certificates, platform_managed, user_managed, auto_rotated, discovery_duration_seconds)
            VALUES (?, ?, ?, ?, ?, ?)
        ''', (cluster_name, total, platform_managed, user_managed, auto_rotated, duration))

        discovery_id = cursor.lastrowid

        # Insert certificates
        for cert in certificates:
            cursor.execute('''
                INSERT INTO certificates
                (discovery_id, namespace, name, resource_type, fingerprint, issuer, expiry, validity_years, managed_status, ca_category)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ''', (
                discovery_id,
                cert.get('namespace'),
                cert.get('name'),
                cert.get('resource_type'),
                cert.get('fingerprint'),
                cert.get('issuer'),
                cert.get('expiry'),
                cert.get('validity_years'),
                cert.get('managed_status'),
                cert.get('ca_category')
            ))

        conn.commit()
        conn.close()

        logger.info(f"Saved discovery #{discovery_id} to database: {total} certificates")

        # Cleanup old discoveries (keep last 30 days)
        cleanup_old_discoveries(retention_days=30)

        return discovery_id
    except Exception as e:
        logger.error(f"Error saving discovery to database: {e}", exc_info=True)
        return None

def get_cert_fingerprint(cert_data):
    """Extract SHA256 fingerprint from certificate data."""
    if not cert_data:
        return ""
    
    try:
        # Handle bytes vs string
        if isinstance(cert_data, bytes):
            cert_data = cert_data.decode('utf-8', errors='ignore')
        
        # Extract first certificate from bundle if needed
        if "-----BEGIN CERTIFICATE-----" in cert_data:
            # Find the first complete certificate
            start_idx = cert_data.find("-----BEGIN CERTIFICATE-----")
            end_idx = cert_data.find("-----END CERTIFICATE-----", start_idx)
            if end_idx == -1:
                return ""
            end_idx += len("-----END CERTIFICATE-----")
            first_cert = cert_data[start_idx:end_idx]
        else:
            first_cert = cert_data
        
        # Parse certificate using cryptography
        cert = x509.load_pem_x509_certificate(first_cert.encode(), default_backend())
        fingerprint = cert.fingerprint(hashes.SHA256()).hex().upper()
        return fingerprint
    except Exception as e:
        logger.debug(f"Error getting fingerprint: {e}")
        # Fallback to openssl if available
        try:
            result = subprocess.run(
                ['openssl', 'x509', '-noout', '-fingerprint', '-sha256'],
                input=first_cert.encode(),
                capture_output=True,
                text=True,
                timeout=5
            )
            if result.returncode == 0:
                fingerprint = result.stdout.split('=')[1].strip().replace(':', '').upper()
                return fingerprint
        except:
            pass
    return ""

def get_cert_issuer(cert_data):
    """Extract issuer from certificate data."""
    if not cert_data:
        return "N/A"
    
    try:
        # Handle bytes vs string
        if isinstance(cert_data, bytes):
            cert_data = cert_data.decode('utf-8', errors='ignore')
        
        # Extract first certificate from bundle if needed
        if "-----BEGIN CERTIFICATE-----" in cert_data:
            # Find the first complete certificate
            start_idx = cert_data.find("-----BEGIN CERTIFICATE-----")
            end_idx = cert_data.find("-----END CERTIFICATE-----", start_idx)
            if end_idx == -1:
                return "N/A"
            end_idx += len("-----END CERTIFICATE-----")
            first_cert = cert_data[start_idx:end_idx]
        else:
            first_cert = cert_data
        
        # Parse certificate using cryptography
        cert = x509.load_pem_x509_certificate(first_cert.encode(), default_backend())
        issuer = cert.issuer.rfc4514_string()
        return issuer
    except Exception as e:
        logger.debug(f"Error getting issuer: {e}")
        # Fallback to openssl if available
        try:
            result = subprocess.run(
                ['openssl', 'x509', '-noout', '-issuer'],
                input=first_cert.encode(),
                capture_output=True,
                text=True,
                timeout=5
            )
            if result.returncode == 0:
                issuer = result.stdout.replace('issuer=', '').strip()
                return issuer
        except:
            pass
    return "N/A"

def get_cert_validity_days(cert_data):
    """Calculate certificate validity in days."""
    if not cert_data:
        return 0
    
    try:
        # Handle bytes vs string
        if isinstance(cert_data, bytes):
            cert_data = cert_data.decode('utf-8', errors='ignore')
        
        # Extract first certificate from bundle if needed
        if "-----BEGIN CERTIFICATE-----" in cert_data:
            # Find the first complete certificate
            start_idx = cert_data.find("-----BEGIN CERTIFICATE-----")
            end_idx = cert_data.find("-----END CERTIFICATE-----", start_idx)
            if end_idx == -1:
                return 0
            end_idx += len("-----END CERTIFICATE-----")
            first_cert = cert_data[start_idx:end_idx]
        else:
            first_cert = cert_data
        
        # Parse certificate using cryptography
        cert = x509.load_pem_x509_certificate(first_cert.encode(), default_backend())
        not_before = cert.not_valid_before
        not_after = cert.not_valid_after
        delta = not_after - not_before
        return delta.days
    except Exception as e:
        logger.debug(f"Error getting validity: {e}")
    return 0

def get_cert_expiry(cert_data):
    """Get certificate expiration date."""
    if not cert_data:
        return ""
    
    try:
        # Handle bytes vs string
        if isinstance(cert_data, bytes):
            cert_data = cert_data.decode('utf-8', errors='ignore')
        
        # Extract first certificate from bundle if needed
        if "-----BEGIN CERTIFICATE-----" in cert_data:
            # Find the first complete certificate
            start_idx = cert_data.find("-----BEGIN CERTIFICATE-----")
            end_idx = cert_data.find("-----END CERTIFICATE-----", start_idx)
            if end_idx == -1:
                return ""
            end_idx += len("-----END CERTIFICATE-----")
            first_cert = cert_data[start_idx:end_idx]
        else:
            first_cert = cert_data
        
        # Parse certificate using cryptography
        cert = x509.load_pem_x509_certificate(first_cert.encode(), default_backend())
        expiry = cert.not_valid_after.strftime('%b %d %H:%M:%S %Y %Z')
        return expiry
    except Exception as e:
        logger.debug(f"Error getting expiry: {e}")
    return ""

def determine_ca_category(issuer, annotations):
    """Determine CA category from issuer and annotations."""
    issuer_lower = issuer.lower()
    annotations_str = str(annotations).lower()
    
    # Service-CA
    if 'service-ca' in annotations_str or 'openshift-service-serving-signer' in issuer_lower:
        return "Service-CA"
    
    # Cluster-Proxy CA
    if 'open-cluster-management:cluster-proxy' in issuer_lower or 'cluster-proxy' in issuer_lower:
        return "Cluster-Proxy CA"
    
    # Kube-CSR-Signer
    if 'kube-csr-signer' in issuer_lower:
        return "Kube-CSR-Signer"
    
    # Cluster-Manager-Webhook
    if 'cluster-manager-webhook' in issuer_lower:
        return "Cluster-Manager-Webhook"
    
    # OVN CA
    if 'openshift-ovn-kubernetes' in issuer_lower:
        return "OVN CA"
    
    # Monitoring CA
    if 'openshift-cluster-monitoring' in issuer_lower:
        return "Monitoring CA"
    
    # Konnectivity CA
    if 'konnectivity-signer' in issuer_lower:
        return "Konnectivity CA"
    
    # Ingress CA
    if 'ingress-operator' in issuer_lower:
        return "Ingress CA"
    
    # OLM CA
    if 'olm-selfsigned' in issuer_lower:
        return "OLM CA"
    
    # External CA
    if 'accvraiz1' in issuer_lower or 'pkiaccv' in issuer_lower:
        return "External CA"
    
    # Platform-CA
    if 'root-ca' in issuer_lower or 'kube-apiserver-to-kubelet-signer' in issuer_lower:
        return "Platform-CA"
    
    # Generic platform patterns
    if any(x in issuer_lower for x in ['etcd', 'kube-apiserver', 'kube-controller-manager', 'openshift', 'kubernetes']):
        return "Platform-CA"
    
    return "Unknown"

def is_platform_namespace(namespace):
    """Check if namespace is a platform namespace."""
    if namespace.startswith('openshift-') and namespace != 'openshift-config':
        return True
    if namespace.startswith('kubernetes-'):
        return True
    if namespace in ['openshift', 'openshift-config-managed', 'kube-system', 'kube-public', 'default', 'kubernetes']:
        return True
    return False

def determine_managed_status(resource_type, name, namespace, cert_data, issuer, validity_days, annotations, labels):
    """Determine if certificate is platform-managed or user-managed."""
    owning_component = annotations.get('openshift.io/owning-component', '')
    cert_not_after = annotations.get('auth.openshift.io/certificate-not-after', '')
    cert_not_before = annotations.get('auth.openshift.io/certificate-not-before', '')
    managed_cert_type = labels.get('auth.openshift.io/managed-certificate-type', '')
    
    # Check if 10-year certificate
    is_10_year = validity_days >= 3650  # 10 years
    
    # User-provided certificates in openshift-config
    if namespace == 'openshift-config' and resource_type == 'secret':
        # Would need to check cluster config resources - simplified for now
        pass
    
    # kube-root-ca.crt special case
    if resource_type == 'configmap' and name == 'kube-root-ca.crt':
        if is_10_year:
            return "Platform-Managed (10-Year, Not Auto-Rotated)", "Kubernetes-managed configmap with platform certificates"
        return "Platform-Managed (Auto-Rotated)", "Kubernetes-managed configmap with platform certificates"
    
    # Check owning-component annotation
    if owning_component:
        return "Platform-Managed (Auto-Rotated)", f"Issuer: {issuer}; {validity_days} days validity"
    
    # Check platform namespace
    if is_platform_namespace(namespace):
        if is_10_year:
            return "Platform-Managed (10-Year, Not Auto-Rotated)", f"Issuer: {issuer}; {validity_days} days validity"
        if cert_not_after:
            return "Platform-Managed (Auto-Rotated)", f"Issuer: {issuer}; {validity_days} days validity"
        return "Platform-Managed (Auto-Rotated)", f"Issuer: {issuer}; {validity_days} days validity"
    
    # Check rotation annotation
    if cert_not_after:
        return "Platform-Managed (Auto-Rotated)", f"Issuer: {issuer}; {validity_days} days validity"
    
    # Check issuer patterns (matching bash script logic)
    issuer_lower = issuer.lower()
    if 'service-ca' in issuer_lower or 'openshift-service-serving-signer' in issuer_lower:
        return "Platform-Managed (Auto-Rotated)", f"Service-CA signed; {validity_days} days validity"
    # Cluster-Proxy CA pattern: open-cluster-management:cluster-proxy
    if 'open-cluster-management:cluster-proxy' in issuer_lower or 'cluster-proxy' in issuer_lower:
        return "Platform-Managed (Auto-Rotated)", f"Cluster-Proxy CA signed; {validity_days} days validity"
    # Platform-CA patterns: etcd, kube-apiserver, kube-controller-manager, openshift, kubernetes, kube-csr-signer, cluster-manager-webhook
    platform_ca_patterns = ['etcd', 'kube-apiserver', 'kube-controller-manager', 'openshift', 'kubernetes', 'kube-csr-signer', 'cluster-manager-webhook']
    if any(pattern in issuer_lower for pattern in platform_ca_patterns):
        if is_10_year:
            return "Platform-Managed (10-Year, Not Auto-Rotated)", f"Platform-CA signed; {validity_days} days validity"
        return "Platform-Managed (Auto-Rotated)", f"Platform-CA signed; {validity_days} days validity"
    
    # Check managed label
    if managed_cert_type:
        if is_10_year:
            return "Platform-Managed (10-Year, Not Auto-Rotated)", f"Issuer: {issuer}; {validity_days} days validity"
        return "Platform-Managed (Auto-Rotated)", f"Issuer: {issuer}; {validity_days} days validity"
    
    # Default: User-Managed
    return "User-Managed (Not Auto-Rotated)", f"Issuer: {issuer}; {validity_days} days validity"

def process_resource(v1, resource_type, name, namespace):
    """Process a secret or configmap to extract certificate information."""
    try:
        if resource_type == 'secret':
            obj = v1.read_namespaced_secret(name, namespace)
            data = obj.data or {}
            
            # Check for certificate fields
            cert_fields = []
            cert_data = None
            
            if 'tls.crt' in data:
                cert_fields.append('tls.crt')
                try:
                    cert_data = base64.b64decode(data['tls.crt']).decode('utf-8', errors='ignore')
                except:
                    return None
            elif 'ca.crt' in data:
                cert_fields.append('ca.crt')
                try:
                    cert_data = base64.b64decode(data['ca.crt']).decode('utf-8', errors='ignore')
                except:
                    return None
            elif 'cert.crt' in data:
                cert_fields.append('cert.crt')
                try:
                    cert_data = base64.b64decode(data['cert.crt']).decode('utf-8', errors='ignore')
                except:
                    return None
            
            if not cert_data or len(cert_data) < 100:  # Basic validation
                return None
            
            annotations = obj.metadata.annotations or {}
            labels = obj.metadata.labels or {}
            
        elif resource_type == 'configmap':
            v1_cm = client.CoreV1Api()
            obj = v1_cm.read_namespaced_config_map(name, namespace)
            data = obj.data or {}
            
            cert_fields = []
            cert_data = None
            
            if 'ca-bundle.crt' in data:
                cert_fields.append('ca-bundle.crt')
                cert_data = data['ca-bundle.crt']
            elif 'tls.crt' in data:
                cert_fields.append('tls.crt')
                cert_data = data['tls.crt']
            elif 'ca.crt' in data:
                cert_fields.append('ca.crt')
                cert_data = data['ca.crt']
            elif 'cert.crt' in data:
                cert_fields.append('cert.crt')
                cert_data = data['cert.crt']
            
            if not cert_data or len(cert_data) < 100:  # Basic validation
                return None
            
            annotations = obj.metadata.annotations or {}
            labels = obj.metadata.labels or {}
        else:
            return None
        
        # Extract certificate information - skip if parsing fails
        try:
            fingerprint = get_cert_fingerprint(cert_data)
            issuer = get_cert_issuer(cert_data)
            validity_days = get_cert_validity_days(cert_data)
            expiry = get_cert_expiry(cert_data)
        except Exception as e:
            # Skip certificates that can't be parsed
            return None
        
        # Only proceed if we got basic info
        if not issuer or issuer == "N/A":
            return None
        
        validity_years = validity_days // 365 if validity_days > 0 else 0
        ca_category = determine_ca_category(issuer, annotations)
        managed_status, managed_details = determine_managed_status(
            resource_type, name, namespace, cert_data, issuer, validity_days, annotations, labels
        )
        
        # Build relevant annotations (one per line)
        relevant_annos = []
        if 'openshift.io/owning-component' in annotations:
            relevant_annos.append(f"openshift.io/owning-component: {annotations['openshift.io/owning-component']}")
        if 'auth.openshift.io/certificate-not-before' in annotations:
            relevant_annos.append(f"auth.openshift.io/certificate-not-before: {annotations['auth.openshift.io/certificate-not-before']}")
        if 'auth.openshift.io/certificate-not-after' in annotations:
            relevant_annos.append(f"auth.openshift.io/certificate-not-after: {annotations['auth.openshift.io/certificate-not-after']}")
        
        return {
            'resource_type': resource_type,
            'name': name,
            'namespace': namespace,
            'data_fields': ', '.join(cert_fields),
            'validity_years': validity_years,
            'expiry': expiry,
            'fingerprint': fingerprint,
            'managed_status': managed_status,
            'managed_details': managed_details,
            'ca_category': ca_category,
            'relevant_annotations': '\n'.join(relevant_annos) if relevant_annos else '',
            'issuer': issuer
        }
    except ApiException as e:
        if e.status != 404:
            logger.warning(f"Error processing {resource_type} {namespace}/{name}: {e}")
        return None
    except Exception as e:
        logger.warning(f"Error processing {resource_type} {namespace}/{name}: {e}")
        return None

def discover_certificates():
    """Discover all certificates in the cluster."""
    v1 = client.CoreV1Api()
    certificates = []
    
    # Get all secrets
    try:
        secrets = v1.list_secret_for_all_namespaces()
        for secret in secrets.items:
            data = secret.data or {}
            # Check if has certificate fields
            if any(field in data for field in ['tls.crt', 'ca.crt', 'cert.crt']):
                cert_info = process_resource(v1, 'secret', secret.metadata.name, secret.metadata.namespace)
                if cert_info:
                    certificates.append(cert_info)
    except Exception as e:
        logger.error(f"Error listing secrets: {e}")
    
    # Get all configmaps
    try:
        configmaps = v1.list_config_map_for_all_namespaces()
        for cm in configmaps.items:
            data = cm.data or {}
            # Check if has certificate fields
            if any(field in data for field in ['ca-bundle.crt', 'tls.crt', 'ca.crt', 'cert.crt']):
                cert_info = process_resource(v1, 'configmap', cm.metadata.name, cm.metadata.namespace)
                if cert_info:
                    certificates.append(cert_info)
    except Exception as e:
        logger.error(f"Error listing configmaps: {e}")
    
    return certificates

@app.route('/')
def index():
    """Main page displaying certificate discovery results."""
    try:
        # Get cached certificate data
        certificates, cluster_name, last_update = cert_cache.get_data()

        # Use last update time or current time
        if last_update:
            generated_time = last_update.strftime('%Y-%m-%d %H:%M:%S UTC')
        else:
            generated_time = datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M:%S UTC')

        # Statistics
        total = len(certificates)
        platform_managed = len([c for c in certificates if c and 'Platform-Managed' in c.get('managed_status', '')])
        user_managed = len([c for c in certificates if c and 'User-Managed' in c.get('managed_status', '')])
        auto_rotated = len([c for c in certificates if c and 'Auto-Rotated' in c.get('managed_status', '')])

        # Filter out None values
        certificates = [c for c in certificates if c is not None]

        return render_template_string(HTML_TEMPLATE,
            certificates=certificates,
            cluster_name=cluster_name,
            generated_time=generated_time,
            total=total,
            platform_managed=platform_managed,
            user_managed=user_managed,
            auto_rotated=auto_rotated
        )
    except Exception as e:
        import traceback
        error_msg = f"Error: {str(e)}\n{traceback.format_exc()}"
        logger.error(f"Error in index route: {error_msg}")
        return f"<html><body><h1>Error</h1><pre>{error_msg}</pre></body></html>", 500

@app.route('/health')
def health():
    """Health check endpoint that verifies Kubernetes API connectivity."""
    try:
        # Verify we can connect to Kubernetes API
        v1 = client.CoreV1Api()
        v1.list_namespace(limit=1)
        return "OK", 200
    except Exception as e:
        logger.error(f"Health check failed: {e}")
        return f"FAILED: {str(e)}", 503

@app.route('/api/certificates')
def api_certificates():
    """API endpoint returning JSON data."""
    try:
        # Get cached certificate data
        certificates, cluster_name, last_update = cert_cache.get_data()
        return jsonify({
            'certificates': certificates,
            'cluster_name': cluster_name,
            'last_update': last_update.isoformat() if last_update else None,
            'total': len(certificates)
        })
    except Exception as e:
        logger.error(f"Error in API endpoint: {e}", exc_info=True)
        return jsonify({'error': str(e)}), 500

@app.route('/api/history')
def api_history():
    """Get list of all discovery runs from database."""
    try:
        if not os.path.exists(DB_PATH):
            return jsonify({'error': 'Database not available - PV may not be mounted'}), 503

        conn = sqlite3.connect(DB_PATH)
        conn.row_factory = sqlite3.Row
        cursor = conn.cursor()

        cursor.execute('''
            SELECT id, timestamp, cluster_name, total_certificates as certificate_count,
                   platform_managed, user_managed, auto_rotated, discovery_duration_seconds
            FROM certificate_discoveries
            ORDER BY timestamp DESC
            LIMIT 100
        ''')

        discoveries = [dict(row) for row in cursor.fetchall()]
        conn.close()

        return jsonify(discoveries)
    except Exception as e:
        logger.error(f"Error in history endpoint: {e}", exc_info=True)
        return jsonify({'error': str(e)}), 500

@app.route('/api/history/<int:discovery_id>')
def api_history_detail(discovery_id):
    """Get certificates from a specific discovery run."""
    try:
        if not os.path.exists(DB_PATH):
            return jsonify({'error': 'Database not available - PV may not be mounted'}), 503

        conn = sqlite3.connect(DB_PATH)
        conn.row_factory = sqlite3.Row
        cursor = conn.cursor()

        # Get discovery metadata
        cursor.execute('''
            SELECT id, timestamp, cluster_name, total_certificates as certificate_count,
                   platform_managed, user_managed, auto_rotated, discovery_duration_seconds
            FROM certificate_discoveries
            WHERE id = ?
        ''', (discovery_id,))

        discovery = cursor.fetchone()
        if not discovery:
            conn.close()
            return jsonify({'error': 'Discovery not found'}), 404

        # Get certificates
        cursor.execute('''
            SELECT * FROM certificates
            WHERE discovery_id = ?
        ''', (discovery_id,))

        certificates = [dict(row) for row in cursor.fetchall()]
        conn.close()

        return jsonify({
            'discovery': dict(discovery),
            'certificates': certificates
        })
    except Exception as e:
        logger.error(f"Error in history detail endpoint: {e}", exc_info=True)
        return jsonify({'error': str(e)}), 500

@app.route('/api/changes')
def api_changes():
    """Show changes between last two discovery runs."""
    try:
        if not os.path.exists(DB_PATH):
            return jsonify({'error': 'Database not available - PV may not be mounted'}), 503

        conn = sqlite3.connect(DB_PATH)
        conn.row_factory = sqlite3.Row
        cursor = conn.cursor()

        # Get last two discoveries
        cursor.execute('''
            SELECT id, timestamp FROM certificate_discoveries
            ORDER BY timestamp DESC
            LIMIT 2
        ''')

        discoveries = [dict(row) for row in cursor.fetchall()]

        if len(discoveries) < 2:
            conn.close()
            return jsonify({'message': 'Need at least 2 discovery runs to compare'})

        older_id = discoveries[1]['id']
        newer_id = discoveries[0]['id']

        # Get older certificates
        cursor.execute('''
            SELECT namespace, name, fingerprint FROM certificates
            WHERE discovery_id = ?
        ''', (older_id,))
        old_certs = {(row['namespace'], row['name']): row['fingerprint'] for row in cursor.fetchall()}

        # Get newer certificates
        cursor.execute('''
            SELECT namespace, name, fingerprint FROM certificates
            WHERE discovery_id = ?
        ''', (newer_id,))
        new_certs = {(row['namespace'], row['name']): row['fingerprint'] for row in cursor.fetchall()}

        conn.close()

        # Detect changes
        added = [k for k in new_certs if k not in old_certs]
        removed = [k for k in old_certs if k not in new_certs]
        changed = [k for k in new_certs if k in old_certs and new_certs[k] != old_certs[k]]

        return jsonify({
            'older_discovery': discoveries[1],
            'newer_discovery': discoveries[0],
            'summary': {
                'added': len(added),
                'removed': len(removed),
                'changed': len(changed)
            },
            'details': {
                'added': [{'namespace': k[0], 'name': k[1]} for k in added],
                'removed': [{'namespace': k[0], 'name': k[1]} for k in removed],
                'changed': [{'namespace': k[0], 'name': k[1]} for k in changed]
            }
        })
    except Exception as e:
        logger.error(f"Error in changes endpoint: {e}", exc_info=True)
        return jsonify({'error': str(e)}), 500

# HTML Template with same color scheme
HTML_TEMPLATE = '''
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>OpenShift Certificate Discovery</title>
    <meta http-equiv="refresh" content="300">
    <style>
        body {
            font-family: "RedHatText", "Overpass", "Overpass Overpass", "Red Hat Text", "RedHatText", Arial, sans-serif;
            margin: 0;
            padding: 20px;
            background: #F0F0F0;
            color: #151515;
            min-height: 100vh;
        }
        .header {
            background: #FFFFFF;
            padding: 30px;
            border-radius: 4px;
            margin-bottom: 20px;
            box-shadow: 0 1px 3px rgba(0, 0, 0, 0.1);
            border: 1px solid #E0E0E0;
        }
        .header h1 {
            margin: 0 0 10px 0;
            font-size: 2.5em;
            color: #151515;
            font-weight: 400;
        }
        .header p {
            color: #6A6A6A;
            margin: 0;
        }
        .summary {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
            gap: 20px;
            margin: 20px 0;
        }
        .summary-card {
            background: #FFFFFF;
            padding: 20px;
            border-radius: 4px;
            text-align: center;
            border: 1px solid #E0E0E0;
            box-shadow: 0 1px 3px rgba(0, 0, 0, 0.1);
        }
        .summary-card h3 {
            margin: 0 0 10px 0;
            color: #6A6A6A;
            font-size: 0.9em;
            font-weight: 400;
        }
        .summary-count {
            font-size: 2.5em;
            font-weight: 400;
            margin: 10px 0;
            color: #151515;
        }
        .cert-table {
            width: 100%;
            border-collapse: collapse;
            margin: 20px 0;
            background: #FFFFFF;
            border-radius: 4px;
            overflow: hidden;
            font-size: 0.9em;
            box-shadow: 0 1px 3px rgba(0, 0, 0, 0.1);
            border: 1px solid #E0E0E0;
        }
        .cert-table th {
            background: #F5F5F5;
            color: #151515;
            padding: 15px 12px;
            text-align: left;
            font-weight: 600;
            border-bottom: 2px solid #E0E0E0;
            font-size: 0.85em;
            text-transform: uppercase;
            letter-spacing: 0.5px;
        }
        .cert-table td {
            padding: 12px;
            border-bottom: 1px solid #E0E0E0;
            vertical-align: top;
            color: #151515;
        }
        .cert-table tr:hover {
            background: #F8F9FA;
        }
        .status-good { 
            background: #E8F5E9; 
            color: #28A745;
            font-weight: 400;
            padding: 4px 8px;
            border-radius: 3px;
            display: inline-block;
        }
        .status-warning { 
            background: #FFF3CD; 
            color: #FFC107;
            font-weight: 400;
            padding: 4px 8px;
            border-radius: 3px;
            display: inline-block;
        }
        .status-critical { 
            background: #F8D7DA; 
            color: #DC3545;
            font-weight: 400;
            padding: 4px 8px;
            border-radius: 3px;
            display: inline-block;
        }
        .status-user {
            background: #E9ECEF;
            color: #6A6A6A;
            font-weight: 400;
            padding: 4px 8px;
            border-radius: 3px;
            display: inline-block;
        }
        .info-box {
            background: #E6F7FF;
            border-left: 4px solid #007BFF;
            padding: 15px;
            margin: 15px 0;
            border-radius: 4px;
        }
        .info-box strong {
            color: #151515;
        }
        .refresh-info {
            text-align: center;
            margin-top: 30px;
            color: #6A6A6A;
            font-style: italic;
            font-size: 0.9em;
        }
        .annotations-cell {
            max-width: 500px;
            min-width: 400px;
            font-size: 0.85em;
            word-wrap: break-word;
            color: #6A6A6A;
            white-space: pre-line;
            line-height: 1.6;
        }
        .managed-details-cell {
            max-width: 200px;
            min-width: 150px;
            font-size: 0.85em;
            word-wrap: break-word;
            color: #151515;
        }
        .managed-status-cell {
            min-width: 220px;
            max-width: 280px;
        }
        a {
            color: #007BFF;
            text-decoration: none;
        }
        a:hover {
            text-decoration: underline;
        }
    </style>
</head>
<body>
    <div class="header">
        <h1>🔐 OpenShift Certificate Discovery</h1>
        <p>Cluster-wide certificate analysis using certificate discovery logic</p>
        <div class="info-box">
            <strong>📊 Generated:</strong> {{ generated_time }} | <strong>Cluster:</strong> {{ cluster_name }}
        </div>
    </div>

    <div class="summary">
        <div class="summary-card">
            <h3>Total Certificates</h3>
            <div class="summary-count">{{ total }}</div>
        </div>
        <div class="summary-card">
            <h3>Platform-Managed</h3>
            <div class="summary-count" style="color: #28A745;">{{ platform_managed }}</div>
        </div>
        <div class="summary-card">
            <h3>User-Managed</h3>
            <div class="summary-count" style="color: #6A6A6A;">{{ user_managed }}</div>
        </div>
        <div class="summary-card">
            <h3>Auto-Rotated</h3>
            <div class="summary-count" style="color: #007BFF;">{{ auto_rotated }}</div>
        </div>
    </div>

    <table class="cert-table">
        <thead>
            <tr>
                <th>Resource Type</th>
                <th>Name</th>
                <th>Namespace</th>
                <th>Data Fields</th>
                <th>Validity (Years)</th>
                <th>Expiry</th>
                <th>Fingerprint</th>
                <th>Managed Status</th>
                <th>Managed Details</th>
                <th>CA Category</th>
                <th>TLS Registry annotations</th>
            </tr>
        </thead>
        <tbody>
            {% for cert in certificates %}
            <tr>
                <td>{{ cert.resource_type }}</td>
                <td>{{ cert.name }}</td>
                <td>{{ cert.namespace }}</td>
                <td>{{ cert.data_fields }}</td>
                <td>{{ cert.validity_years }}</td>
                <td>{{ cert.expiry }}</td>
                <td style="font-family: monospace; font-size: 0.8em;">{{ cert.fingerprint[:16] }}...</td>
                <td class="managed-status-cell {% if 'Platform-Managed' in cert.managed_status and 'Auto-Rotated' in cert.managed_status %}status-good{% elif 'Platform-Managed' in cert.managed_status and '10-Year' in cert.managed_status %}status-warning{% elif 'User-Managed' in cert.managed_status %}status-user{% else %}status-critical{% endif %}">
                    {{ cert.managed_status }}
                </td>
                <td class="managed-details-cell">{{ cert.managed_details }}</td>
                <td>{{ cert.ca_category }}</td>
                <td class="annotations-cell">{{ cert.relevant_annotations }}</td>
            </tr>
            {% endfor %}
        </tbody>
    </table>

    <div class="refresh-info">
        Page auto-refreshes every 5 minutes | Last updated: {{ generated_time }}
    </div>
</body>
    </html>
'''

# Initialize database on startup (if PV is mounted)
db_available = init_database()
if db_available:
    logger.info("Database initialized and available for historical tracking")
else:
    logger.warning("Database not available - running without persistent storage")

# Start background refresh thread after all functions are defined
cert_cache.start_background_refresh()

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=8080, debug=False)

