#!/bin/bash

# Name of the docker image
IMAGE_NAME="cmatriximage"

# Check si l'image existe
if [[ "$(docker images -q $IMAGE_NAME 2> /dev/null)" == "" ]]; then
    echo "Building the image $IMAGE_NAME..."
    docker build -t $IMAGE_NAME .
else
    echo "Image $IMAGE_NAME already exists. Running the container..."
fi

# Run the Docker container
docker run --rm -it $IMAGE_NAME
