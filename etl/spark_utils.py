"""Construcción de la SparkSession (JDBC + S3A hacia ministack + catálogo Iceberg)."""
from pyspark.sql import SparkSession


def construir_spark(params: dict) -> SparkSession:
    sp, lh = params["spark"], params["lakehouse"]
    ice = lh["iceberg"]
    warehouse = f"s3a://{lh['bucket']}/{ice['prefijo_warehouse']}"

    builder = (
        SparkSession.builder.appName(sp["app_name"])
        .master(sp["master"])
        .config("spark.driver.memory", sp["driver_memory"])
        .config("spark.sql.shuffle.partitions", str(sp["shuffle_partitions"]))
        .config("spark.sql.session.timeZone", sp["timezone"])
        .config("spark.ui.showConsoleProgress", "false")
        # S3A hacia ministack (emulador AWS)
        .config("spark.hadoop.fs.s3a.impl", "org.apache.hadoop.fs.s3a.S3AFileSystem")
        .config("spark.hadoop.fs.s3a.endpoint", lh["endpoint"])
        .config("spark.hadoop.fs.s3a.path.style.access", "true")
        .config("spark.hadoop.fs.s3a.connection.ssl.enabled", "false")
        .config("spark.hadoop.fs.s3a.access.key", lh["access_key"])
        .config("spark.hadoop.fs.s3a.secret.key", lh["secret_key"])
        .config(
            "spark.hadoop.fs.s3a.aws.credentials.provider",
            "org.apache.hadoop.fs.s3a.SimpleAWSCredentialsProvider",
        )
        .config("spark.hadoop.mapreduce.fileoutputcommitter.marksuccessfuljobs", "false")
    )
    if ice["habilitado"]:
        cat = ice["catalogo"]
        builder = (
            builder.config(
                "spark.sql.extensions",
                "org.apache.iceberg.spark.extensions.IcebergSparkSessionExtensions",
            )
            .config(f"spark.sql.catalog.{cat}", "org.apache.iceberg.spark.SparkCatalog")
            .config(f"spark.sql.catalog.{cat}.type", "hadoop")
            .config(f"spark.sql.catalog.{cat}.warehouse", warehouse)
        )
    spark = builder.getOrCreate()
    spark.sparkContext.setLogLevel("ERROR")
    return spark
