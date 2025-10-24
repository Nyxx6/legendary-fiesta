# Stage 1: Build
FROM alpine:3.19 AS builder

# Installation des dépendances de compilation
RUN apk add --no-cache \
    git \
    gcc \
    make \
    musl-dev \
    ncurses-dev \
    ncurses-static \
    autoconf \
    automake

# Clonage du repository CMatrix
WORKDIR /build
RUN git clone https://github.com/abishekvashok/cmatrix.git

# Compilation de CMatrix
WORKDIR /build/cmatrix
RUN autoreconf -i && \
    ./configure LDFLAGS="-static" && \
    make

# Stage 2: Image finale minimale
FROM scratch

# Copie uniquement du binaire compilé
COPY --from=builder /build/cmatrix/cmatrix /cmatrix

# Copie des fichiers terminfo nécessaires pour ncurses
COPY --from=builder /usr/share/terminfo/x/xterm /terminfo/x/xterm
COPY --from=builder /usr/share/terminfo/x/xterm-256color /terminfo/x/xterm-256color

# Variables d'environnement
ENV TERM=xterm-256color
ENV TERMINFO=/terminfo

# Définir le point d'entrée
ENTRYPOINT ["/cmatrix"]

# Options par défaut (peut être surchargé)
CMD ["-b"]
