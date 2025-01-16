# Gemini RTSW RPM Repository

This repository contains tools and configuration files for managing and uploading RPM packages to the Gemini RTSW Package Registry.

## Contents

- **`Dockerfile`**: A Dockerfile for creating an image based on Rocky Linux 9 with the required Gemini RTSW software.
- **`gem-rtsw.repo`**: Repository configuration file for accessing Gemini RTSW RPMs.
- **`upload_rpms.sh`**: A script to upload RPM packages to the GitLab Package Registry.
- **`rpms/`**: Directory where RPM packages are downloaded and stored.

## Usage

### 1. Prepare the Environment
Ensure you have the following:
- A valid GitLab personal access token with `write_registry` permissions.
- The `rpm` and `curl` tools installed on your system.

### 2. Download RPMs
Run the following command to download all RPMs from the specified repositories into the `rpms/` directory:
```bash
dnf repoquery --disablerepo="*" \
    --enablerepo="gem-rtsw-epics-base-unstable-2024q3" \
    --enablerepo="gem-rtsw-support-unstable-2024q3" \
    --enablerepo="gem-rtsw-app-unstable-2024q3" \
    --enablerepo="gem-rtsw-common-unstable-2024q3" \
    --queryformat="%{name}" | xargs -r -n 1 dnf download --resolve --destdir=./rpms
```

### 3. Upload RPMs
Use the `upload_rpms.sh` script to upload RPMs to the GitLab Package Registry:
```bash
./upload_rpms.sh
```

Update the `TOKEN` variable in the script with your personal access token before running.

### 4. Verify Uploads
Check the uploaded RPMs in the **Packages & Registries > Package Registry** section of your GitLab project.

---

## Notes
- The `rpms/` directory is used for temporary storage of downloaded RPMs.
- The `upload_rpms.sh` script requires an active internet connection and valid permissions on the GitLab project.

---

## Contributing
Feel free to submit issues or merge requests to enhance this repository.

---

## License
This project is licensed under the MIT License.


