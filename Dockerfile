# Switch to Rocky 8 to match the RPM version
FROM rockylinux:8

# Copy RPMs from the GHCR RPM repo container
COPY --from=ghcr.io/gemini-rtsw/rpm-repo:latest /rpm-repo /tmp/rpm-repo

# Create a local yum repo from the container RPMs
RUN echo $'\n\
[local-rpm-repo]\n\
name=Local RPM Repository\n\
baseurl=file:///tmp/rpm-repo/\n\
enabled=1\n\
gpgcheck=0\n\
' > /etc/yum.repos.d/local-rpm-repo.repo

# Enable PowerTools and EPEL
RUN dnf install -y epel-release && \
    dnf install -y dnf-plugins-core && \
    dnf config-manager --set-enabled powertools

# Update metadata and install packages
RUN dnf makecache --refresh && \
    dnf install -y gcc-c++ && \
    dnf install -y conserver conserver-client && \
    dnf install -y --nobest --allowerasing $(dnf list available --repo local-rpm-repo -q | grep -v "Available Packages" | cut -f1 -d' ')

# Verify installation
CMD rpm -qa
