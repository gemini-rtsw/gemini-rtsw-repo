# Switch to Rocky 8 to match the RPM version
FROM rockylinux:8

# RPM repo container must be running on the same Docker network as 'rpm-repo'
# e.g.: docker build --network=rpm-repo-net ...
ARG RPM_REPO_URL=http://rpm-repo:8080/rpm-repo/

# Create yum repo pointing at the RPM repo container
RUN echo -e "[github-rpm-repo]\nname=GitHub RPM Repository\nbaseurl=${RPM_REPO_URL}\nenabled=1\ngpgcheck=0" \
    > /etc/yum.repos.d/rpm-repo.repo

# Enable PowerTools and EPEL
RUN dnf install -y epel-release && \
    dnf install -y dnf-plugins-core && \
    dnf config-manager --set-enabled powertools

# Update metadata and install packages
RUN dnf makecache --refresh && \
    dnf install -y gcc-c++ && \
    dnf install -y conserver conserver-client && \
    dnf install -y --nobest --allowerasing $(dnf list available --repo github-rpm-repo -q | grep -v "Available Packages" | cut -f1 -d' ')

# Verify installation
CMD rpm -qa
