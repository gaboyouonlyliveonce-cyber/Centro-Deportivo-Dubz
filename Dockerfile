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

# --- Capas adicionales para Sección 3 (Iceberg + S3A hacia ministack:4566 + PYTHONPATH) ---
USER root
ARG MVN=https://repo1.maven.org/maven2
RUN cd /usr/local/spark/jars \
    && wget -q ${MVN}/org/apache/iceberg/iceberg-spark-runtime-3.5_2.12/1.5.2/iceberg-spark-runtime-3.5_2.12-1.5.2.jar \
    && wget -q ${MVN}/org/apache/iceberg/iceberg-aws-bundle/1.5.2/iceberg-aws-bundle-1.5.2.jar \
    && wget -q ${MVN}/org/apache/hadoop/hadoop-aws/3.3.4/hadoop-aws-3.3.4.jar \
    && wget -q ${MVN}/com/amazonaws/aws-java-sdk-bundle/1.12.262/aws-java-sdk-bundle-1.12.262.jar \
    && mkdir -p /app/etl /app/data_lake /home/jovyan/data_lake/curated \
    && chown -R ${NB_UID}:${NB_GID} /app /home/jovyan/data_lake

USER ${NB_UID}
RUN pip install --no-cache-dir boto3
ENV PYTHONPATH=/usr/local/spark/python:/usr/local/spark/python/lib/py4j-0.10.9.7-src.zip:/app/etl
