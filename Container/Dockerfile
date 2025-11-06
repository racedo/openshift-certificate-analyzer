FROM registry.redhat.io/ubi9/python-311:latest

USER root

# Install openssl for certificate parsing
RUN microdnf install -y openssl && \
    microdnf clean all

WORKDIR /app

# Copy requirements and install Python dependencies
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy application code
COPY app.py .

# Create non-root user
RUN useradd -u 1001 -r -g 0 -s /sbin/nologin -c "cert-discovery app user" certapp && \
    chown -R 1001:0 /app && \
    chmod -R g=u /app

USER 1001

EXPOSE 8080

CMD ["python3", "app.py"]


