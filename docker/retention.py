#!/usr/bin/env python3
import os
import sys
import json
import subprocess
import re
from datetime import datetime, timedelta

# 环境变量
REMOTE = os.environ.get("RCLONE_REMOTE", "")
PREFIX = os.environ.get("BACKUP_FILENAME_PREFIX", "vaultwarden")
# 策略模式: days, count, smart, forever
MODE = os.environ.get("RETENTION_MODE", "days") 
# 参数
KEEP_DAYS = int(os.environ.get("BACKUP_RETAIN_DAYS", 14))
KEEP_COUNT = int(os.environ.get("BACKUP_RETAIN_COUNT", 30))

def get_file_date(filename):
    # 尝试从文件名解析日期: vaultwarden-20231127-090000.tar.gz
    match = re.search(r"(\d{8})-(\d{6})", filename)
    if match:
        d_str = match.group(1) + match.group(2)
        return datetime.strptime(d_str, "%Y%m%d%H%M%S")
    return None

def get_remote_files():
    cmd = ["rclone", "lsjson", REMOTE, "--files-only", "--no-mimetype"]
    try:
        result = subprocess.check_output(cmd).decode('utf-8')
        files = json.loads(result)
        # 过滤出符合前缀的文件
        backup_files = []
        for f in files:
            if f['Name'].startswith(PREFIX) and ('.tar.' in f['Name'] or f['Name'].endswith('.zip')):
                dt = get_file_date(f['Name'])
                if dt:
                    f['Date'] = dt
                    backup_files.append(f)
        # 按时间倒序排列（最新的在最前）
        backup_files.sort(key=lambda x: x['Date'], reverse=True)
        return backup_files
    except Exception as e:
        print(f"Error listing files: {e}")
        return []

def delete_files(files_to_delete):
    if not files_to_delete:
        print("✅ No files to delete.")
        return

    print(f"🧹 Deleting {len(files_to_delete)} old backup(s)...")
    # 将要删除的文件路径写入临时文件，使用 files-from 批量删除
    with open("/tmp/delete_list.txt", "w") as f:
        for file in files_to_delete:
            f.write(f"{file['Path']}\n")
    
    cmd = ["rclone", "delete", REMOTE, "--files-from", "/tmp/delete_list.txt"]
    subprocess.call(cmd)
    os.remove("/tmp/delete_list.txt")

def strategy_days(files):
    """保留指定天数内的文件"""
    print(f"running strategy: DAYS (Keep {KEEP_DAYS} days)")
    cutoff = datetime.now() - timedelta(days=KEEP_DAYS)
    to_delete = []
    for f in files:
        if f['Date'] < cutoff:
            to_delete.append(f)
    return to_delete

def strategy_count(files):
    """保留最近 N 个文件"""
    print(f"running strategy: COUNT (Keep latest {KEEP_COUNT})")
    if len(files) <= KEEP_COUNT:
        return []
    return files[KEEP_COUNT:] # 删除第 N 个之后的所有文件

def strategy_smart(files):
    """
    智能策略 (GFS):
    - 保留最近 7 天的每日备份 (保留当天的最后一份)
    - 保留最近 4 周的每周备份 (保留周日的最后一份)
    - 保留最近 12 个月的每月备份 (保留每月的最后一份)
    - 总是保留最新的那一份
    """
    print("running strategy: SMART (7 days, 4 weeks, 12 months)")
    if not files:
        return []

    keep_paths = set()
    
    # 总是保留最新的
    keep_paths.add(files[0]['Path'])

    now = datetime.now()
    
    # 辅助函数：将日期转为 key
    def to_day_key(d): return d.strftime("%Y-%m-%d")
    def to_week_key(d): return d.strftime("%Y-W%W")
    def to_month_key(d): return d.strftime("%Y-%m")

    # 1. 最近 7 天
    for i in range(7):
        target_day = (now - timedelta(days=i)).strftime("%Y-%m-%d")
        # 找到属于这一天的所有文件，取最新的一个
        day_files = [f for f in files if to_day_key(f['Date']) == target_day]
        if day_files:
            keep_paths.add(day_files[0]['Path']) # 列表已排序，0是最新的

    # 2. 最近 4 周
    for i in range(4):
        # 粗略计算周
        target_week = (now - timedelta(weeks=i)).strftime("%Y-W%W")
        week_files = [f for f in files if to_week_key(f['Date']) == target_week]
        if week_files:
            keep_paths.add(week_files[0]['Path'])

    # 3. 最近 12 个月
    for i in range(12):
        # 计算月份
        # 这里的逻辑稍微简化，通过迭代找到前 i 个月的 key
        # 实际逻辑：生成当前月，上个月...的 key
        year = now.year
        month = now.month - i
        while month <= 0:
            month += 12
            year -= 1
        target_month = f"{year}-{month:02d}"
        
        month_files = [f for f in files if to_month_key(f['Date']) == target_month]
        if month_files:
            keep_paths.add(month_files[0]['Path'])

    # 计算需要删除的文件
    to_delete = []
    for f in files:
        if f['Path'] not in keep_paths:
            to_delete.append(f)
            
    return to_delete

def main():
    if MODE == "forever":
        print("Strategy: FOREVER (Skipping cleanup)")
        return

    if not REMOTE:
        print("RCLONE_REMOTE not set, skipping cleanup.")
        return

    files = get_remote_files()
    if not files:
        print("No remote files found.")
        return

    print(f"Total backup files found: {len(files)}")
    
    to_delete = []
    if MODE == "days":
        to_delete = strategy_days(files)
    elif MODE == "count":
        to_delete = strategy_count(files)
    elif MODE == "smart":
        to_delete = strategy_smart(files)
    else:
        print(f"Unknown mode: {MODE}, defaulting to days")
        to_delete = strategy_days(files)

    delete_files(to_delete)

if __name__ == "__main__":
    main()
