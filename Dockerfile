# Build Stage: Build the CMatrix binary
FROM alpine:3.19 AS cmatrixbuilder

# Install necessary build dependencies
RUN apk update --no-cache && \
  apk add --no-cache \
    git \
    autoconf \
    automake \
    alpine-sdk \
    ncurses-dev \
    ncurses-static

# Create a clean directory for the repository and clone it
WORKDIR /cmatrix
RUN git clone https://github.com/abishekvashok/cmatrix.git . && \
  autoreconf -i && \
  ./configure LDFLAGS="-static" && \
  make
  
# Final Stage: Minimized image with only the necessary runtime dependencies
FROM alpine:3.19

# Labeling image metadata
LABEL org.opencontainers.image.authors="Ryan Galazka" \
      org.opencontainers.image.description="Container image for https://github.com/abishekvashok/cmatrix"

# Install terminfo files and create a non-root user
RUN apk update --no-cache && \
  apk add --no-cache \
    ncurses-terminfo-base && \
  adduser -g "cmatrixuser" -s /usr/sbin/nologin -D -H cmatrixuser

# Copy the statically compiled cmatrix binary from the build stage
COPY --from=cmatrixbuilder /cmatrix/cmatrix /usr/local/bin/cmatrix

# Set the user to run the application as a non-root user
USER cmatrixuser

# Set default environment variable for terminfo path
ENV TERMINFO=/usr/share/terminfo

# Set entrypoint and default arguments
ENTRYPOINT ["/usr/local/bin/cmatrix"]
CMD ["-b"]
