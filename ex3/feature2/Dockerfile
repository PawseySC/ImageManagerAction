FROM python:3.9-slim

WORKDIR /app

# 复制应用文件
COPY hello.py .
COPY requirements.txt .

# 安装依赖
RUN pip install --no-cache-dir -r requirements.txt

# 运行应用
CMD ["python3", "hello.py"]
LABEL org.opencontainers.image.version=0.0.4 org.opencontainers.image.devmode=false org.opencontainers.image.noscan=false org.opencontainers.image.platform=x86
