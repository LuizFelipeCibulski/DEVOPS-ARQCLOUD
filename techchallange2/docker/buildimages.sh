#!/bin/bash
registry="628409561285.dkr.ecr.us-east-1.amazonaws.com"
mapfile -t array < <(ls -d */ | awk -F'/' '{print $1}')
for item in "${array[@]}"; do
    cd "$item"
    if [ -f "Dockerfile" ]; then
        echo "Building: $(pwd)"
        docker build --no-cache -t "$registry/$item" .
        docker push "$registry/$item"
    else
        echo "Dockerfile não encontrado em: $item"
    fi
    cd ..
done

