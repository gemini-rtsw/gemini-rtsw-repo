# Runs a local mirror of ghcr.io/gemini-rtsw/rpm-repo:latest as a systemd
# service, and a timer that pulls new :latest images and restarts it.
# Built by gemini-rtsw-ci (profile: lightweight).

# $GIT_HASH is passed in by build_rpm.sh; git is only the fallback.
%define git_hash %(if [ -n "$GIT_HASH" ]; then echo "$GIT_HASH"; else git rev-parse --short HEAD 2>/dev/null || echo nogit; fi)

Name:      rpm-repo-mirror
Version:   1.0.1
Release:   1.git%{git_hash}%{?dist}
Summary:   Local mirror of the gemini-rtsw RPM repository, kept current by systemd
License:   Proprietary
Source0:   %{name}-%{version}.tar.gz
BuildArch: noarch
BuildRequires: systemd-rpm-macros
Requires:  systemd
Requires:  util-linux

%description
Serves ghcr.io/gemini-rtsw/rpm-repo:latest over HTTP (default port 8081,
path /rpm-repo/) and checks every minute for a new image. Pulls run as
the user in /etc/sysconfig/rpm-repo-mirror (default software), which needs
a docker login to ghcr.io with read:packages.

%prep
%autosetup

%build

%install
install -Dpm 0644 deploy/%{name}.service        %{buildroot}%{_unitdir}/%{name}.service
install -Dpm 0644 deploy/%{name}-update.service %{buildroot}%{_unitdir}/%{name}-update.service
install -Dpm 0644 deploy/%{name}-update.timer   %{buildroot}%{_unitdir}/%{name}-update.timer
install -Dpm 0755 deploy/pull.sh                %{buildroot}%{_libexecdir}/%{name}/pull
install -Dpm 0644 deploy/%{name}.sysconfig      %{buildroot}%{_sysconfdir}/sysconfig/%{name}

%post
%systemd_post %{name}.service %{name}-update.timer
%preun
%systemd_preun %{name}.service %{name}-update.timer
%postun
%systemd_postun_with_restart %{name}.service

%files
%{_unitdir}/%{name}.service
%{_unitdir}/%{name}-update.service
%{_unitdir}/%{name}-update.timer
%{_libexecdir}/%{name}/pull
%config(noreplace) %{_sysconfdir}/sysconfig/%{name}

%changelog
* Wed Nov 18 2026 Hawi Stecher <hawi.stecher@noirlab.edu> - 1.0.1-1
- Update timer polls every minute (was 15 min + up to 60 s random delay).

* Tue Nov 17 2026 Hawi Stecher <hawi.stecher@noirlab.edu> - 1.0.0-1
- Initial package: mirror service and 15-minute update timer.
