#!/bin/bash
echo "Starting Milvus services..."
docker compose up -d

echo "Waiting for services to be ready..."
sleep 30

echo "Checking service health..."
docker compose ps

echo ""
echo "Services available at:"
echo "  - Milvus API: http://localhost:19530"
echo "  - Milvus WebUI: http://localhost:9091/webui/"
echo "  - Attu GUI: http://localhost:8000"
echo "  - MinIO Console: http://localhost:9001 (minioadmin/minioadmin)"
echo ""
echo "To test the connection, run:"
echo "  pip install -r requirements.txt"
echo "  python milvus_connection.py"
