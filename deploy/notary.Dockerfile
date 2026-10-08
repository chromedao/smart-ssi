# Smart-SSI notary: the TLSNotary verifier that co-signs MPC-TLS sessions without seeing their content.
# Build from the repository root:  docker build -f deploy/notary.Dockerfile -t smart-ssi-notary .
FROM rust:1-bookworm AS build
WORKDIR /src
RUN git clone --depth 1 --branch v0.1.0-alpha.15 https://github.com/tlsnotary/tlsn.git vendor/tlsn
COPY prover prover
RUN cd prover && cargo build --release --locked --bin smart-ssi-prover

FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates && rm -rf /var/lib/apt/lists/*
COPY --from=build /src/prover/target/release/smart-ssi-prover /usr/local/bin/smart-ssi-prover
# The signing key lives on a volume, created on first start. It is never part of the image.
VOLUME /data
EXPOSE 7047
ENTRYPOINT ["smart-ssi-prover", "notary", "--listen", "0.0.0.0:7047", "--key", "/data/notary.key"]
