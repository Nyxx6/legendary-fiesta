mkdir -p ~/ejbca-test && cd ~/ejbca-test

# docker-compose.yml
cat > docker-compose.yml << 'EOF'
services:
  ejbca-db:
    image: mariadb:10.11
    container_name: ejbca-db
    restart: unless-stopped
    environment:
      MYSQL_ROOT_PASSWORD: rootpassword
      MYSQL_DATABASE: ejbca
      MYSQL_USER: ejbca
      MYSQL_PASSWORD: ejbcapassword
    volumes:
      - ejbca-db-data:/var/lib/mysql
    networks:
      - ejbca-net

  ejbca:
    image: keyfactor/ejbca-ce:latest
    container_name: ejbca-ce
    restart: unless-stopped
    depends_on:
      - ejbca-db
    environment:
      # Database connection (MariaDB)
      DATABASE_JDBC_URL: jdbc:mariadb://ejbca-db:3306/ejbca?characterEncoding=utf-8
      DATABASE_USER: ejbca
      DATABASE_PASSWORD: ejbcapassword

      # TLS setup: "true" = generate self-signed cert + superadmin cert
      TLS_SETUP_ENABLED: "true"

      # Hostname for generated TLS cert
      HTTPSERVER_HOSTNAME: localhost

      # Optional: password for encryption (change in production!)
      PASSWORD_ENCRYPTION_KEY: changeme1234567890

      # Superadmin access (printed in logs on first start)
      EJBCA_CLI_DEFAULTPASSWORD: ejbca

    ports:
      - "8080:8080"   # HTTP (for initial access)
      - "8443:8443"   # HTTPS Admin GUI
    volumes:
      - ejbca-persistent:/mnt/persistent
    networks:
      - ejbca-net

  serles-acme:
    image: joepitt91/serles-acme-docker:latest   # Or build from joepitt91 repo if needed
    container_name: serles-acme
    restart: unless-stopped
    depends_on:
      - ejbca
    environment:
      # EJBCA Web Service API URL (internal network)
      EJBCA_API: https://ejbca:8443/ejbca/ejbcaws/ejbcaws?wsdl
      EJBCA_API_VERIFY: "false"   # Skip TLS verify (self-signed in test)

      # EJBCA CA/Profile names (create them in EJBCA first!)
      CA_NAME: ManagementCA
      CERT_PROFILE: SERVER
      ENTITY_PROFILE: EMPTY

      # Allowed IPs for ACME requests (0.0.0.0/0 for test)
      ALLOWED_IPS: 0.0.0.0/0,::/0

    ports:
      - "80:80"   # ACME HTTP (behind reverse proxy in prod)
    volumes:
      - ./serles-client.pem:/app/client.pem:ro   # Mount your EJBCA client cert+key
    networks:
      - ejbca-net

volumes:
  ejbca-db-data:
  ejbca-persistent:

networks:
  ejbca-net:
    driver: bridge
EOF

docker compose up -d
docker compose logs -f ejbca
docker compose logs -f serles-acme
