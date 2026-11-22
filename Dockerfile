FROM jupyter/pyspark-notebook:latest

USER root

RUN apt-get update && apt-get install -y --no-install-recommends \
    libpq-dev \
    gcc \
    wget \
    && rm -rf /var/lib/apt/lists/*

RUN wget -q https://jdbc.postgresql.org/download/postgresql-42.7.3.jar -P /usr/local/spark/jars/

USER ${NB_UID}

# --upgrade numba/llvmlite: la imagen base trae numba 0.57 (numpy<1.25), que choca con pymc
RUN pip install --no-cache-dir --upgrade \
    numba \
    llvmlite \
    psycopg2-binary \
    sqlalchemy \
    neo4j \
    scipy \
    statsmodels \
    pymc \
    arviz \
    quantecon \
    pulp \
    ortools \
    networkx \
    seaborn \
    plotly
