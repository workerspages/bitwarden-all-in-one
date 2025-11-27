#!/usr/bin/env python3
import os
import sys
import json
import subprocess
import re
from datetime import datetime, timedelta

# 1. 读取环境变量
REMOTE = os.environ.get("RCLONE_REMOTE", "")
PREFIX = os.environ.get("BACKUP_FILENAME_PREFIX", "vaultwarden")
MODE = os.environ.get("RETENTION_MODE", "smart") 
try:
    KEEP_DAYS = int(os.environ.get("BACKUP_RETAIN_DAYS", 14))
except:
    KEEP_DAYS = 14
try:
    KEEP_COUNT = int(os.environ.get("BACKUP_RETAIN_COUNT", 30))
except:
    KEEP_COUNT = 30

def log(msg):
    print(f"[Retention] {msg}", flush=True)

def get_file_date(filename):
    # 匹配 vaultwarden-20231127-090000.tar.gz
    match = re.search(r"(\d{8})-(\d{6})", filename)
    if match:
        d_str = match.group(1) + match.group(2)
        try:
            return datetime.strptime(d_str, "%Y%m%d%H%M%S")
        except ValueError:
            return None
    return None

def get_remote_files():
    if not REMOTE:
        log("Error: RCLONE_REMOTE is empty.")
        return []
    
    # 获取文件列表
    cmd = ["rclone", "lsjson", REMOTE, "--files-only", "--no-mimetype"]
    try:
        # 设置超时，防止卡死
        result = subprocess.check_output(cmd, timeout=60).decode('utf-8')
        files = json.loads(result)
        
        backup_files = []
        for f in files:
            # 严格匹配前缀，防止误删其他文件
            if f['Name'].startswith(PREFIX) and ('.tar.' in f['Name'] or f['Name'].endswith('.zip')):
                dt = get_file_date(f['Name'])
                if dt:
                    f['Date'] = dt
                    backup_files.append(f)
        
        # 按时间倒序排列 (最新的在 index 0)
        backup_files.sort(key=lambda x: x['Date'], reverse=True)
        return backup_files
    except Exception as e:
        log(f"Error listing files: {e}")
        return []

def delete_files(files_to_delete):
    if not files_to_delete:
        log("No files marked for deletion.")
        return

    log(f"Executing delete for {len(files_to_delete)} files...")
    
    # 写入临时文件列表供 rclone 使用
    with open("/tmp/delete_list.txt", "w") as f:
        for file in files_to_delete:
            f.write(f"{file['Path']}\n")
            log(f"  -> DELETE: {file['Name']}")
    
    cmd = ["rclone", "delete", REMOTE, "--files-from", "/tmp/delete_list.txt"]
    subprocess.call(cmd)
    if os.path.exists("/tmp/delete_list.txt"):
        os.remove("/tmp/delete_list.txt")
    log("Delete operation completed.")

def run_strategy(files):
    log(f"Mode: {MODE} | Total Files: {len(files)}")
    
    if not files:
        return []

    to_delete = []

    if MODE == "count":
        log(f"Strategy: Keep latest {KEEP_COUNT} files")
        if len(files) > KEEP_COUNT:
            # 保留前 N 个，剩下的全部删除
            to_delete = files[KEEP_COUNT:]
            log(f"  -> Found {len(to_delete)} redundant files.")
        else:
            log("  -> File count is within limit.")

    elif MODE == "days":
        log(f"Strategy: Keep files within {KEEP_DAYS} days")
        cutoff = datetime.now() - timedelta(days=KEEP_DAYS)
        for f in files:
            if f['Date'] < cutoff:
                to_delete.append(f)

    elif MODE == "smart":
        log("Strategy: Smart (GFS)")
        # 总是保留最新的
        keep_paths = {files[0]['Path']}
        now = datetime.now()
        
        # 7 Days
        for i in range(7):
            target = (now - timedelta(days=i)).strftime("%Y-%m-%d")
            found = next((f for f in files if f['Date'].strftime("%Y-%m-%d") == target), None)
            if found: keep_paths.add(found['Path'])
            
        # 4 Weeks (Simplified)
        for i in range(4):
            target = (now - timedelta(weeks=i)).strftime("%Y-W%W")
            found = next((f for f in files if f['Date'].strftime("%Y-W%W") == target), None)
            if found: keep_paths.add(found['Path'])

        # 12 Months
        for i in range(12):
            # 简单回推月份
            curr = now.replace(day=1)
            # 这种日期计算比较粗糙，但足够用于备份策略
            target_y = curr.year
            target_m = curr.month - i
            while target_m <= 0:
                target_m += 12
                target_y -= 1
            target = f"{target_y}-{target_m:02d}"
            
            found = next((f for f in files if f['Date'].strftime("%Y-%m") == target), None)
            if found: keep_paths.add(found['Path'])

        # 计算差集
        for f in files:
            if f['Path'] not in keep_paths:
                to_delete.append(f)
                
    elif MODE == "forever":
        log("Strategy: Forever (Do nothing)")
        
    return to_delete

if __name__ == "__main__":
    print("--- Starting Retention Check ---")
    files = get_remote_files()
    if files:
        to_del = run_strategy(files)
        delete_files(to_del)
    else:
        log("Skipping retention check (no files found).")
    print("--- End Retention Check ---")
