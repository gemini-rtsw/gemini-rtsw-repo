# Use Rocky Linux 9 as the base image
FROM rockylinux:9

# Set up environment variables for non-interactive installs
ENV DEBIAN_FRONTEND=noninteractive

# Install required tools
RUN dnf -y install dnf-plugins-core && dnf clean all

# Add the GitLab Package Registry repository
RUN dnf config-manager --add-repo https://gitlab.com/api/v4/projects/66226575/packages/rpm/generic/ && \
    dnf config-manager --save --setopt=gitlab*.gpgcheck=0 && \
    dnf config-manager --save --setopt=gitlab*.repo_gpgcheck=0 && \
    dnf config-manager --save --setopt=gitlab*.sslverify=1 && \
    dnf config-manager --save --setopt=gitlab*.metadata_expire=300 && \
    dnf config-manager --save --setopt=gitlab*.baseurl=https://gitlab.com/api/v4/projects/66226575/packages/rpm/generic/ && \
    dnf config-manager --save --setopt=gitlab*.name="Gemini RTSW Repository" && \
    dnf config-manager --save --setopt=gitlab*.username=gitlab-ci-token && \
    dnf config-manager --save --setopt=gitlab*.password=glpat-eX-vwr3j7nPZmtYohnXF

# Refresh metadata and test installation
RUN dnf clean all && dnf makecache && dnf -y install softTCS_mk

# Default command
CMD ["/bin/bash"]
