# Backup runner: rclone + the tools utils/backup.sh needs, installed at build
# time instead of on every container start.
ARG RCLONE_VERSION=1.76.0
FROM rclone/rclone:${RCLONE_VERSION}

RUN apk add --no-cache sqlite zip unzip

# busybox crond in the foreground; -d 8 sends crond's own messages to stderr.
# The backup script itself logs to the container output (see utils/backup.sh).
ENTRYPOINT ["crond", "-f", "-d", "8"]
