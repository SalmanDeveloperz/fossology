# FOSSology Kubernetes PoC image
# SPDX-FileCopyrightText: © 2026 Muhammad Salman
#
# SPDX-License-Identifier: FSFAP
#
# Description: Extends the stock FOSSology image with an SSH server so the
#              same image can run as web, scheduler or agent worker.

ARG BASE_IMAGE=fossology:latest
FROM ${BASE_IMAGE}

RUN DEBIAN_FRONTEND=noninteractive apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      openssh-server \
 && rm -rf /var/lib/apt/lists/* \
 && rm -f /etc/ssh/ssh_host_*

# Unlock fossy for public-key login only; no password is ever set.
RUN usermod -p '*' fossy

COPY sshd-fossology.conf /etc/ssh/sshd_config.d/fossology.conf
# Validate the sshd configuration at build time; host keys are per pod.
RUN mkdir -p /run/sshd && ssh-keygen -A && sshd -t && rm -f /etc/ssh/ssh_host_*

COPY k8s-entrypoint.sh /fossology/k8s-entrypoint.sh
RUN chmod +x /fossology/k8s-entrypoint.sh

ENTRYPOINT ["/fossology/k8s-entrypoint.sh"]
