mkdir -p ~/ejbca-test && cd ~/ejbca-test

# docker-compose.yml
cat > docker-compose.yml << 'EOF'
services:
  db:
    image: mariadb:10.11
    container_name: ejbca-db
    environment:
      MYSQL_ROOT_PASSWORD: rootpass
      MYSQL_DATABASE: ejbca
      MYSQL_USER: ejbca
      MYSQL_PASSWORD: ejbcapass
    volumes:
      - db-data:/var/lib/mysql
    networks:
      - internal

  ejbca:
    image: keyfactor/ejbca-ce:latest
    container_name: ejbca
    depends_on:
      - db
    environment:
      DATABASE_JDBC_URL: jdbc:mariadb://db:3306/ejbca?characterEncoding=utf-8
      DATABASE_USER: ejbca
      DATABASE_PASSWORD: ejbcapass
      TLS_SETUP_ENABLED: "simple"
      HTTPSERVER_HOSTNAME: localhost
      PASSWORD_ENCRYPTION_KEY: ejbca123456
    ports:
      - "8080:8080"
      - "8443:8443"
    volumes:
      - ejbca-data:/mnt/persistent
    networks:
      - internal

volumes:
  db-data:
  ejbca-data:

networks:
  internal:
    driver: bridge
EOF

docker compose up -d
docker compose logs -f ejbca

# create superadmin profile, generate certificate and import it in browser.
# restart ejbca
# the management ca is for internal trust between ejbca services
# create CAs and generate certificate for acme
