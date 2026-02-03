mkdir -p ~/ejbca-test && cd ~/ejbca-test

# docker-compose.yml
cat > docker-compose.yml << 'EOF'
services:
  db:
    image: mariadb:10.11
    container_name: ejbca-db
    environment:
      MYSQL_ROOT_PASSWORD: rootpassword
      MYSQL_DATABASE: ejbca
      MYSQL_USER: ejbca
      MYSQL_PASSWORD: ejbcapassword
    volumes:
      - db-data:/var/lib/mysql
    networks:
      - internal

  ejbca:
    image: keyfactor/ejbca-ce:latest
    container_name: ejbca-ce
    depends_on:
      - db
    environment:
      DATABASE_JDBC_URL: jdbc:mariadb://db:3306/ejbca?characterEncoding=utf-8
      DATABASE_USER: ejbca
      DATABASE_PASSWORD: ejbcapassword

      TLS_SETUP_ENABLED: "simple"
      LOG_LEVEL_APP: INFO
      LOG_LEVEL_SERVER: INFO

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
