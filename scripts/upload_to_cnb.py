#!/usr/bin/env python3
"""
RustDesk CNB Release / Commit 附件上传脚本

通过 CNB Open API 3步上传流程将编译产物上传到 CNB 仓库:
  1. 获取预签名上传 URL (asset-upload-url)
  2. PUT 二进制文件到存储
  3. 确认上传完成 (asset-upload-confirmation)

特性:
  - 自动重试 (指数退避, 最多3次)
  - 大文件分块上传 (chunked transfer)
  - 网络超时处理
  - Release / Commit 两种上传模式
  - 完善的错误处理与汇总

用法:
    # 上传到 Release (自动创建)
    python3 scripts/upload_to_cnb.py --repo org/repo --version 1.4.6 --artifacts-dir ./release-artifacts

    # 上传到已存在的 Release tag
    python3 scripts/upload_to_cnb.py --repo org/repo --version 1.4.6 --tag v1.4.6

    # 上传到 commit 附件
    python3 scripts/upload_to_cnb.py --repo org/repo --commit abc123 --artifacts-dir ./release-artifacts

    # CI/CD 中使用 (自动读取环境变量)
    CNB_TOKEN=xxx CNB_REPO_SLUG=org/repo CNB_COMMIT=abc123 python3 scripts/upload_to_cnb.py

环境变量:
    CNB_TOKEN          - CNB API 认证令牌 (CI 中自动注入)
    CNB_API_ENDPOINT   - CNB API 地址 (默认: https://api.cnb.cool)
    CNB_REPO_SLUG      - 当前仓库路径 (CI 中自动注入, 格式: org/repo)
    CNB_COMMIT         - 当前 commit hash (CI 中自动注入)
    CNB_TAG_NAME       - 当前 tag 名 (tag_push 事件自动注入)
    CNB_BUILD_ID       - 当前构建 ID (CI 中自动注入)
"""

import argparse
import glob
import json
import os
import sys
import time
from pathlib import Path
from urllib.parse import urlparse

import requests

# 每块上传大小 (10 MB)
CHUNK_SIZE = 10 * 1024 * 1024

# ============== 配置 ==============
DEFAULT_API_ENDPOINT = "https://api.cnb.cool"
API_BASE = os.environ.get("CNB_API_ENDPOINT", DEFAULT_API_ENDPOINT)
CNB_TOKEN = os.environ.get("CNB_TOKEN", "")


def log_info(msg):
    print(f"[INFO]  {msg}")


def log_warn(msg):
    print(f"[WARN]  {msg}", file=sys.stderr)


def log_error(msg):
    print(f"[ERROR] {msg}", file=sys.stderr)


# ============== HTTP 工具 ==============
def http_session():
    """创建带超时和重试的 HTTP session"""
    session = requests.Session()
    adapter = requests.adapters.HTTPAdapter(
        pool_connections=4,
        pool_maxsize=8,
        max_retries=3,
    )
    session.mount("https://", adapter)
    session.mount("http://", adapter)
    return session


def api_headers(token: str):
    return {
        "Accept": "application/vnd.cnb.api+json",
        "Authorization": f"Bearer {token}",
    }


# ============== 带重试的请求 ==============
def retry_request(func, label="", max_retries=3, base_delay=2):
    """
    对任意可调用对象进行指数退避重试

    Args:
        func: 无参可调用, 返回 requests.Response
        label: 描述信息 (用于日志)
        max_retries: 最大重试次数
        base_delay: 初始延迟秒数 (每次 x2)

    Returns:
        requests.Response

    Raises:
        RuntimeError: 所有重试均失败
    """
    last_exc = None
    for attempt in range(1, max_retries + 1):
        try:
            resp = func()
            return resp
        except (requests.exceptions.ConnectionError,
                requests.exceptions.Timeout,
                requests.exceptions.ReadTimeout,
                requests.exceptions.ChunkedEncodingError) as e:
            last_exc = e
            delay = base_delay * (2 ** (attempt - 1))
            log_warn(f"{label}: 网络错误 (第{attempt}/{max_retries}次): {e}")
            log_warn(f"  {delay}秒后重试...")
            time.sleep(delay)
        except requests.exceptions.HTTPError as e:
            # 4xx 不重试 (客户端错误)
            if 400 <= e.response.status_code < 500:
                raise
            last_exc = e
            delay = base_delay * (2 ** (attempt - 1))
            log_warn(f"{label}: 服务端错误 {e.response.status_code} (第{attempt}/{max_retries}次)")
            log_warn(f"  {delay}秒后重试...")
            time.sleep(delay)

    raise RuntimeError(f"{label}: 重试{max_retries}次后仍失败: {last_exc}")


# ============== CNB API 客户端 ==============
class CNBClient:
    """CNB Open API 客户端 (带重试和超时)"""

    def __init__(self, repo: str, token: str = None, endpoint: str = None):
        self.repo = repo
        self.token = token or CNB_TOKEN
        self.base = (endpoint or API_BASE).rstrip("/")
        if not self.token:
            raise ValueError("CNB_TOKEN 环境变量未设置，请先配置认证令牌")
        self.session = http_session()

    def _url(self, path: str) -> str:
        return f"{self.base}/{self.repo}{path}"

    def _api_get(self, path: str, **kwargs) -> dict:
        url = self._url(path)

        def do():
            return self.session.get(url, headers=api_headers(self.token), timeout=30, **kwargs)

        resp = retry_request(do, label=f"GET {path}")
        if resp.status_code >= 400:
            log_error(f"GET {url} -> {resp.status_code}")
            log_error(f"  Body: {resp.text[:500]}")
            resp.raise_for_status()
        return resp.json()

    def _api_post(self, path: str, json_data: dict = None, **kwargs) -> dict:
        url = self._url(path)

        def do():
            return self.session.post(url, headers=api_headers(self.token),
                                     json=json_data, timeout=30, **kwargs)

        resp = retry_request(do, label=f"POST {path}")
        if resp.status_code >= 400:
            log_error(f"POST {url} -> {resp.status_code}")
            log_error(f"  Body: {resp.text[:500]}")
            resp.raise_for_status()
        return resp.json()

    def _api_post_no_body(self, path: str, **kwargs) -> requests.Response:
        """POST 请求 (无 JSON body, 用于确认接口)"""
        url = self._url(path)

        def do():
            return self.session.post(url, headers=api_headers(self.token), timeout=30, **kwargs)

        resp = retry_request(do, label=f"POST {path}")
        if resp.status_code >= 400:
            log_error(f"POST {url} -> {resp.status_code}")
            log_error(f"  Body: {resp.text[:500]}")
            resp.raise_for_status()
        return resp

    # ---------- Release API ----------

    def create_release(self, tag_name: str, name: str, body: str = "",
                       target_commitish: str = None, draft: bool = False,
                       prerelease: bool = False) -> dict:
        data = {
            "tag_name": tag_name,
            "name": name,
            "body": body,
            "draft": draft,
            "prerelease": prerelease,
        }
        if target_commitish:
            data["target_commitish"] = target_commitish
        return self._api_post("/-/releases", json_data=data)

    def get_release_by_tag(self, tag_name: str) -> dict:
        return self._api_get(f"/-/releases/tags/{tag_name}")

    def get_release_upload_url(self, release_id, asset_name, size,
                                overwrite=False, ttl=0) -> dict:
        """步骤1: 获取 Release 附件预签名上传 URL"""
        data = {
            "asset_name": asset_name,
            "size": size,
            "overwrite": overwrite,
            "ttl": ttl,
        }
        return self._api_post(f"/-/releases/{release_id}/asset-upload-url", json_data=data)

    def confirm_release_upload(self, release_id, upload_token, asset_path, ttl=0):
        """步骤3: 确认 Release 附件上传完成"""
        params = {}
        if ttl:
            params["ttl"] = ttl
        path = f"/-/releases/{release_id}/asset-upload-confirmation/{upload_token}/{asset_path}"
        self._api_post_no_body(path, params=params)

    # ---------- Commit Asset API ----------

    def get_commit_upload_url(self, sha1, asset_name, size, ttl=0) -> dict:
        """步骤1: 获取 commit 附件预签名上传 URL"""
        data = {
            "asset_name": asset_name,
            "size": size,
            "ttl": ttl,
        }
        return self._api_post(f"/-/git/commit-assets/{sha1}/asset-upload-url", json_data=data)

    def confirm_commit_upload(self, sha1, upload_token, asset_path, ttl=0):
        """步骤3: 确认 commit 附件上传完成"""
        params = {}
        if ttl:
            params["ttl"] = ttl
        path = f"/-/git/commit-assets/{sha1}/asset-upload-confirmation/{upload_token}/{asset_path}"
        self._api_post_no_body(path, params=params)


# ============== 上传核心 ==============
def parse_verify_url(verify_url: str) -> tuple:
    """
    从 verify_url 解析 upload_token 和 asset_path

    verify_url 格式: .../asset-upload-confirmation/{upload_token}/{asset_path}
    """
    parsed = urlparse(verify_url)
    path_parts = parsed.path.strip("/").split("/")
    if len(path_parts) >= 2:
        return path_parts[-2], path_parts[-1]
    raise ValueError(f"无法解析 verify_url: {verify_url}")


def upload_file_to_presigned_url(upload_url: str, file_path: Path, label: str = "") -> None:
    """
    步骤2: 将文件分块上传到预签名 URL

    Args:
        upload_url: 预签名 PUT URL
        file_path: 本地文件路径
        label: 日志描述
    """
    file_size = file_path.stat().st_size
    display = label or file_path.name

    # 小文件 (< 50MB) 直接上传
    if file_size < 50 * 1024 * 1024:
        log_info(f"  上传 {display} ({file_size / 1024 / 1024:.1f} MB) ...")

        def do_upload():
            with open(file_path, "rb") as f:
                resp = requests.put(
                    upload_url, data=f,
                    headers={"Content-Type": "application/octet-stream"},
                    timeout=600,
                )
            return resp

        resp = retry_request(do_upload, label=f"PUT {display}", max_retries=3, base_delay=5)
        if resp.status_code >= 400:
            raise RuntimeError(f"上传失败: HTTP {resp.status_code} - {resp.text[:300]}")
        return

    # 大文件: 分块上传
    log_info(f"  分块上传 {display} ({file_size / 1024 / 1024:.1f} MB, 每块 {CHUNK_SIZE // 1024 // 1024} MB) ...")
    uploaded = 0
    with open(file_path, "rb") as f:
        chunk_idx = 0
        while True:
            chunk = f.read(CHUNK_SIZE)
            if not chunk:
                break
            chunk_size = len(chunk)
            content_range = f"bytes {uploaded}-{uploaded + chunk_size - 1}/{file_size}"

            def do_chunk_upload(cr=content_range, ck=chunk):
                return requests.put(
                    upload_url,
                    data=ck,
                    headers={
                        "Content-Type": "application/octet-stream",
                        "Content-Range": cr,
                    },
                    timeout=600,
                )

            resp = retry_request(do_chunk_upload,
                                 label=f"PUT {display} chunk {chunk_idx}",
                                 max_retries=3, base_delay=5)
            if resp.status_code not in (200, 201, 202, 308):
                raise RuntimeError(f"分块 {chunk_idx} 上传失败: HTTP {resp.status_code}")

            uploaded += chunk_size
            chunk_idx += 1
            pct = (uploaded / file_size) * 100
            log_info(f"    进度: {pct:.0f}% ({uploaded / 1024 / 1024:.1f}/{file_size / 1024 / 1024:.1f} MB)")


def upload_to_release(client: CNBClient, release_id: str, file_path: str,
                      overwrite: bool = False, ttl: int = 0) -> dict:
    """完整的 Release 附件上传流程 (3步)"""
    file_path = Path(file_path)
    file_size = file_path.stat().st_size
    asset_name = file_path.name

    # 步骤1: 获取上传 URL
    log_info(f"  [1/3] 获取上传 URL: {asset_name} ({file_size / 1024 / 1024:.1f} MB) ...")
    upload_info = client.get_release_upload_url(
        release_id=release_id,
        asset_name=asset_name,
        size=file_size,
        overwrite=overwrite,
        ttl=ttl,
    )
    upload_url = upload_info["upload_url"]
    verify_url = upload_info["verify_url"]

    # 步骤2: 上传文件
    log_info(f"  [2/3] 上传文件: {asset_name} ...")
    upload_file_to_presigned_url(upload_url, file_path, label=asset_name)

    # 步骤3: 确认上传
    log_info(f"  [3/3] 确认上传: {asset_name} ...")
    upload_token, asset_path = parse_verify_url(verify_url)
    client.confirm_release_upload(
        release_id=release_id,
        upload_token=upload_token,
        asset_path=asset_path,
        ttl=ttl,
    )

    log_info(f"  [OK] 上传完成: {asset_name} ({file_size / 1024 / 1024:.1f} MB)")
    return {"name": asset_name, "size": file_size}


def upload_to_commit(client: CNBClient, sha1: str, file_path: str,
                      ttl: int = 0) -> dict:
    """完整的 commit 附件上传流程 (3步)"""
    file_path = Path(file_path)
    file_size = file_path.stat().st_size
    asset_name = file_path.name

    # 步骤1: 获取上传 URL
    log_info(f"  [1/3] 获取上传 URL: {asset_name} ({file_size / 1024 / 1024:.1f} MB) ...")
    upload_info = client.get_commit_upload_url(
        sha1=sha1,
        asset_name=asset_name,
        size=file_size,
        ttl=ttl,
    )
    upload_url = upload_info["upload_url"]
    verify_url = upload_info["verify_url"]

    # 步骤2: 上传文件
    log_info(f"  [2/3] 上传文件: {asset_name} ...")
    upload_file_to_presigned_url(upload_url, file_path, label=asset_name)

    # 步骤3: 确认上传
    log_info(f"  [3/3] 确认上传: {asset_name} ...")
    upload_token, asset_path = parse_verify_url(verify_url)
    client.confirm_commit_upload(
        sha1=sha1,
        upload_token=upload_token,
        asset_path=asset_path,
        ttl=ttl,
    )

    log_info(f"  [OK] 上传完成: {asset_name} ({file_size / 1024 / 1024:.1f} MB)")
    return {"name": asset_name, "size": file_size}


# ============== 产物查找 ==============
def find_artifacts(artifacts_dir: str, pattern: str = "*") -> list:
    """查找编译产物，排除空文件和 .gitkeep"""
    artifacts = []
    for p in sorted(Path(artifacts_dir).glob(pattern)):
        if p.is_file() and p.stat().st_size > 0 and p.name != ".gitkeep":
            artifacts.append(p)
    return artifacts


def generate_changelog(version: str, artifacts: list) -> str:
    """自动生成 Release 描述"""
    lines = [
        f"## RustDesk {version}",
        "",
        "### 下载",
        "",
    ]
    for artifact in artifacts:
        size_mb = artifact.stat().st_size / 1024 / 1024
        lines.append(f"- `{artifact.name}` ({size_mb:.1f} MB)")
    lines.extend([
        "",
        "### 安装说明",
        "",
        "- **Windows**: 下载 `.exe` 安装包运行",
        "- **macOS**: 下载 `.dmg` 文件，打开后拖拽到 Applications",
        "- **Linux**: 下载 `.deb` 包执行 `sudo dpkg -i xxx.deb`",
        "- **Android**: 下载 `.apk` 文件安装",
        "",
        "---",
        f"*自动构建于 {__import__('datetime').datetime.now().strftime('%Y-%m-%d %H:%M:%S')} UTC*",
    ])
    return "\n".join(lines)


# ============== 主逻辑 ==============
def main():
    parser = argparse.ArgumentParser(
        description="上传 RustDesk 编译产物到 CNB Release / Commit",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
示例:
  # Release 上传
  %(prog)s --repo myorg/rustdesk --version 1.4.6 --artifacts-dir ./release-artifacts
  %(prog)s --repo myorg/rustdesk --version 1.4.6 --tag v1.4.6 --pattern "*.so,*.deb"

  # Commit 附件上传
  %(prog)s --repo myorg/rustdesk --commit abc123 --artifacts-dir ./release-artifacts

  # CI/CD 中 (自动读取 CNB_REPO_SLUG / CNB_COMMIT)
  %(prog)s --artifacts-dir /tmp/artifacts

  # 仅预览不上传
  %(prog)s --repo myorg/rustdesk --artifacts-dir ./release-artifacts --dry-run
        """,
    )
    parser.add_argument("--repo", default=None,
                        help="CNB 仓库路径 (默认读取 CNB_REPO_SLUG)")
    parser.add_argument("--version", default="1.4.6", help="版本号")
    parser.add_argument("--tag", default=None, help="Release tag (默认: v{version})")
    parser.add_argument("--name", default=None, help="Release 名称")
    parser.add_argument("--commit", default=None,
                        help="目标 commit hash (默认读取 CNB_COMMIT)")
    parser.add_argument("--artifacts-dir", default="./release-artifacts", help="产物目录")
    parser.add_argument("--pattern", default="*", help="文件匹配 (逗号分隔)")
    parser.add_argument("--body", default=None, help="Release 描述 (默认自动生成)")
    parser.add_argument("--draft", action="store_true", help="创建为草稿")
    parser.add_argument("--prerelease", action="store_true", help="标记为预发布")
    parser.add_argument("--overwrite", action="store_true", help="覆盖同名文件")
    parser.add_argument("--ttl", type=int, default=0,
                        help="保留天数 (0=永久, 最大180)")
    parser.add_argument("--dry-run", action="store_true", help="仅预览")
    parser.add_argument("--endpoint", default=None, help="API 端点")
    parser.add_argument("--max-retries", type=int, default=3, help="上传重试次数")

    args = parser.parse_args()

    # 从 CI 环境变量自动填充
    repo = args.repo or os.environ.get("CNB_REPO_SLUG", "")
    commit = args.commit or os.environ.get("CNB_COMMIT", "")
    tag_name = args.tag or os.environ.get("CNB_TAG_NAME", "") or f"v{args.version}"

    if not repo:
        log_error("请指定 --repo 或设置 CNB_REPO_SLUG 环境变量")
        sys.exit(1)

    print("=" * 60)
    print(f"  RustDesk CNB 产物上传")
    print(f"  仓库:   {repo}")
    print(f"  版本:   {args.version}")
    print(f"  Tag:    {tag_name}")
    if commit:
        print(f"  Commit: {commit[:12]}")
    print(f"  产物:   {args.artifacts_dir}")
    print("=" * 60)

    # 查找产物
    patterns = args.pattern.split(",")
    all_artifacts = []
    for p in patterns:
        all_artifacts.extend(find_artifacts(args.artifacts_dir, p.strip()))

    if not all_artifacts:
        log_error(f"在 {args.artifacts_dir} 中未找到匹配文件 (pattern: {args.pattern})")
        sys.exit(1)

    total_size = sum(a.stat().st_size for a in all_artifacts)
    print(f"\n找到 {len(all_artifacts)} 个文件 (共 {total_size / 1024 / 1024:.1f} MB):")
    for a in all_artifacts:
        print(f"  - {a.name} ({a.stat().st_size / 1024 / 1024:.1f} MB)")

    if args.dry_run:
        log_info("[DRY RUN] 不执行实际上传")
        sys.exit(0)

    # 创建客户端
    client = CNBClient(repo=repo, endpoint=args.endpoint)

    # ============ 模式1: Commit 附件上传 ============
    if commit:
        log_info(f"\n上传 {len(all_artifacts)} 个文件到 commit {commit[:12]}:")
        success, failed = [], []
        for artifact in all_artifacts:
            try:
                upload_to_commit(
                    client=client,
                    sha1=commit,
                    file_path=str(artifact),
                    ttl=args.ttl,
                )
                success.append(artifact.name)
            except Exception as e:
                log_error(f"  [FAILED] {artifact.name}: {e}")
                failed.append((artifact.name, str(e)))

        print(f"\n{'=' * 60}")
        log_info(f"上传完成: {len(success)} 成功, {len(failed)} 失败")
        if failed:
            for name, err in failed:
                log_error(f"  失败: {name} - {err[:100]}")
        print(f"{'=' * 60}")
        sys.exit(1 if failed else 0)

    # ============ 模式2: Release 附件上传 ============
    release_id = None

    # 尝试获取已存在的 Release
    try:
        release = client.get_release_by_tag(tag_name)
        release_id = release.get("id")
        log_info(f"找到已存在的 Release: {tag_name} (id: {release_id})")
    except requests.exceptions.HTTPError as e:
        if e.response.status_code == 404:
            log_info(f"Release {tag_name} 不存在, 将创建新 Release")
        else:
            log_error(f"查询 Release 失败: {e}")
            sys.exit(1)

    # 创建新 Release
    if not release_id:
        body = args.body or generate_changelog(args.version, all_artifacts)
        release_name = args.name or f"RustDesk {args.version}"
        try:
            release = client.create_release(
                tag_name=tag_name,
                name=release_name,
                body=body,
                draft=args.draft,
                prerelease=args.prerelease,
            )
            release_id = release.get("id")
            log_info(f"Release 已创建: {tag_name} (id: {release_id})")
        except Exception as e:
            log_error(f"创建 Release 失败: {e}")
            sys.exit(1)

    if not release_id:
        log_error("无法获取 Release ID")
        sys.exit(1)

    # 上传附件
    log_info(f"\n上传 {len(all_artifacts)} 个文件到 Release {release_id}:")
    success, failed = [], []
    for artifact in all_artifacts:
        try:
            upload_to_release(
                client=client,
                release_id=release_id,
                file_path=str(artifact),
                overwrite=args.overwrite,
                ttl=args.ttl,
            )
            success.append(artifact.name)
        except Exception as e:
            log_error(f"  [FAILED] {artifact.name}: {e}")
            failed.append((artifact.name, str(e)))

    # 汇总
    print(f"\n{'=' * 60}")
    log_info(f"上传完成: {len(success)} 成功, {len(failed)} 失败")
    if failed:
        for name, err in failed:
            log_error(f"  失败: {name} - {err[:100]}")
    print(f"{'=' * 60}")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
