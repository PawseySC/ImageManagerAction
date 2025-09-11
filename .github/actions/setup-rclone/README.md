# Setup Rclone Action (Enhanced)

这个action提供了rclone的安装、配置和S3操作功能，支持上传和下载模式。

## 功能特性

- **基础功能**: 安装和配置rclone
- **下载模式**: 可选择从S3下载container archive
- **自动加载**: 可选择将下载的archive加载到podman
- **缓存优化**: 复用已安装的rclone二进制文件

## 输入参数

### 基础参数 (所有模式必需)

| 参数 | 必需 | 默认值 | 描述 |
|-----|------|-------|------|
| `access_key_id` | ✅ | - | S3访问密钥ID |
| `secret_access_key` | ✅ | - | S3秘密访问密钥 |
| `endpoint` | ✅ | - | S3端点URL |
| `bucket` | ✅ | - | S3存储桶名称 |
| `destination_path` | ✅ | - | S3中的目标路径 |

### 下载模式参数

| 参数 | 必需 | 默认值 | 描述 |
|-----|------|-------|------|
| `download_mode` | ❌ | `false` | 是否启用下载模式 |
| `dockerfile_name` | ❌* | - | Dockerfile名称 (下载模式时必需) |
| `version` | ❌* | - | 版本号 (下载模式时必需) |
| `load_to_podman` | ❌ | `false` | 是否将archive加载到podman |

*当 `download_mode=true` 时为必需参数

## 输出

### 基础输出

| 输出 | 描述 |
|-----|------|
| `rclone_installed` | 是否在此次运行中安装了rclone |

### 下载模式输出

| 输出 | 描述 |
|-----|------|
| `archive_downloaded` | 是否成功下载了archive |
| `archive_name` | 下载的archive文件名 |
| `archive_path` | archive的完整本地路径 |
| `archive_source` | archive的S3源路径 |
| `image_tag` | 镜像标签 (仅当load_to_podman=true时) |

## 使用示例

### 1. 仅设置rclone (上传模式)

```yaml
- name: Setup rclone for upload
  uses: ./.github/actions/setup-rclone
  with:
    access_key_id: ${{ secrets.ACACIA_ACCESS_KEY_ID }}
    secret_access_key: ${{ secrets.ACACIA_SECRET_ACCESS_KEY }}
    endpoint: https://projects.pawsey.org.au
    bucket: ${{ vars.ACACIA_BUCKETNAME }}
    destination_path: ex1_0.0.5.tar
    # download_mode默认为false

- name: Upload file
  run: |
    ./rclone copy my_file.tar pawsey0012:${{ vars.ACACIA_BUCKETNAME }}/
```

### 2. 下载模式 (仅下载)

```yaml
- name: Download archive from S3
  id: download
  uses: ./.github/actions/setup-rclone
  with:
    access_key_id: ${{ secrets.ACACIA_ACCESS_KEY_ID }}
    secret_access_key: ${{ secrets.ACACIA_SECRET_ACCESS_KEY }}
    endpoint: https://projects.pawsey.org.au
    bucket: ${{ vars.ACACIA_BUCKETNAME }}
    destination_path: ex1_0.0.5.tar
    download_mode: true
    dockerfile_name: ex1
    version: 0.0.5
    load_to_podman: false

- name: Use downloaded archive
  run: |
    echo "Downloaded: ${{ steps.download.outputs.archive_name }}"
    ls -la ${{ steps.download.outputs.archive_path }}
```

### 3. 下载并加载到podman

```yaml
- name: Download and load image
  id: download_load
  uses: ./.github/actions/setup-rclone
  with:
    access_key_id: ${{ secrets.ACACIA_ACCESS_KEY_ID }}
    secret_access_key: ${{ secrets.ACACIA_SECRET_ACCESS_KEY }}
    endpoint: https://projects.pawsey.org.au
    bucket: ${{ vars.ACACIA_BUCKETNAME }}
    destination_path: ex1_0.0.5.tar
    download_mode: true
    dockerfile_name: ex1
    version: 0.0.5
    load_to_podman: true

- name: Use loaded image
  run: |
    echo "Image loaded: ${{ steps.download_load.outputs.image_tag }}"
    podman images | grep ex1
```

## 工作流集成

这个增强的action现在在CI/CD workflow的不同阶段使用：

1. **BUILD-job**: `download_mode: false` - 仅设置rclone用于上传
2. **SCAN-job**: `download_mode: true, load_to_podman: false` - 下载用于扫描
3. **PUSH-PRIV-job**: `download_mode: true, load_to_podman: false` - 下载后手动加载
4. **PUSH-PUBLIC-job**: `download_mode: true, load_to_podman: true` - 下载并自动加载

## 设计优势

- **向后兼容**: 原有的upload功能完全保留
- **统一接口**: 单一action处理所有rclone相关操作
- **减少重复**: 避免多个action之间的代码重复
- **灵活配置**: 通过参数控制不同的使用模式
