# Switch to Rocky 8 to match the RPM version
FROM rockylinux:8

# Create repository configuration with authentication
RUN echo $'\n\
[gitlab-rpm-repo]\n\
name=GitLab RPM Repository\n\
baseurl=https://oauth2:glpat-eX-vwr3j7nPZmtYohnXF@gitlab.com/api/v4/projects/66226575/packages/generic/rpm-repo/1.0/\n\
enabled=1\n\
gpgcheck=0\n\
' > /etc/yum.repos.d/gitlab-rpm-repo.repo

# Enable PowerTools and EPEL
RUN dnf install -y epel-release && \
    dnf install -y dnf-plugins-core && \
    dnf config-manager --set-enabled powertools

# Update metadata and install package
RUN dnf makecache --refresh && \
    dnf install -y conserver conserver-client && \
    dnf install -y softTCS_mk

# Verify installation
CMD rpm -qa | grep softTCS_mk
