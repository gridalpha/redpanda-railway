FROM redpandadata/redpanda:latest

# The base image ends on USER redpanda; every build step below needs root.
USER root

COPY entrypoint.sh /usr/local/bin/redpanda-railway-entrypoint.sh
RUN chmod 0755 /usr/local/bin/redpanda-railway-entrypoint.sh \
 && bash -n /usr/local/bin/redpanda-railway-entrypoint.sh \
 && command -v setpriv >/dev/null \
 && command -v curl >/dev/null

# The external Kafka listener the Railway TCP proxy targets is not among the base
# image's exposed ports.
EXPOSE 19092

# Declaring ENTRYPOINT clears the inherited `redpanda start --overprovisioned`
# CMD, which is deliberate: the entrypoint execs the broker binary itself so it
# can write a redpanda.yaml that rpk's own flag parser would strip fields from.
ENTRYPOINT ["/usr/local/bin/redpanda-railway-entrypoint.sh"]
