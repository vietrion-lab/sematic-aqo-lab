#!/bin/bash
set -e

echo "==== Step 1: System Dependencies Setup ===="

# Update system packages
sudo apt-get update
sudo apt-get install -y \
    build-essential \
    git \
    wget \
    curl \
    libreadline-dev \
    zlib1g-dev \
    bison \
    flex \
    python3 \
    python3-pip \
    python3-venv

echo "✅ System dependencies installed (including Python 3 + venv)"