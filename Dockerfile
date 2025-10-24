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
  make && \
  strip /cmatrix/cmatrix  # Strip the binary to reduce its size

# Final Stage: Minimal runtime image
FROM alpine:3.19

# Labeling image metadata
LABEL org.opencontainers.image.authors="Ceryne Ziane" \
      org.opencontainers.image.description="Container image for https://github.com/abishekvashok/cmatrix"

# Install ncurses-terminfo-base for terminfo support
RUN apk update --no-cache && \
  apk add --no-cache \
    ncurses-terminfo-base && \
  adduser -g "cmatrixuser" -s /usr/sbin/nologin -D -H cmatrixuser

# Set environment variables for terminfo and terminal type
ENV TERM xterm-256color
ENV TERMINFO=/usr/share/terminfo

# Copy the stripped, statically compiled cmatrix binary from the build stage
COPY --from=cmatrixbuilder /cmatrix/cmatrix /usr/local/bin/cmatrix

# Set the user to run the application as a non-root user
USER cmatrixuser

# Entry point and default argument
ENTRYPOINT ["/usr/local/bin/cmatrix"]
CMD ["-b"]
