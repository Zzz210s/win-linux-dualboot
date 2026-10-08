#!/usr/bin/env bash
# 库文件:非步骤脚本
# 用途:验收汇总渲染——把验收总控的逐项判定落成 docs/08-verification.md 的固定格式(表头/逐项表/失败项/已知例外/结论行)。
#   从 dbk-obs.sh 拆出(原文件逼近 200 行上限);渲染结果与旧内联实现逐字节一致。
# 调用约定:调用方先 source dbk-obs.sh(它的末尾会替调用方 source 本库),然后:
#   dbk_write_accept_summary <汇总路径> <设备名> <判定侧> <判定脚本> <依据文档> <结论行> <人工已确认0/1>
#     逐项行从 **stdin** 读,格式「编号|组|状态|原因|关联卡」(状态 ∈ pass/fail/manual/skip);
#     先写 <路径>.new 再 mv(原子落盘);0 = 已写(或 mv 成功);非 0 = 写失败(调用方需显式处理)。
# 只定义函数、只往调用方给的路径写一份文件;不设置 shell 选项、不执行动作、不主动落盘。
# **末尾不加任何条件语句**(被 source 时返回非 0 会让带 set -e 的调用方静默退 1)。
# 夹具级验证,真机未跑。

# dbk_write_accept_summary <汇总路径> <设备名> <判定侧> <判定脚本> <依据文档> <结论行> <人工已确认0/1>
#   逐项行从 stdin 读,格式「编号|组|状态|原因|关联卡」(状态 ∈ pass/fail/manual/skip):渲染 08-verification.md
#   的固定表头/逐项表/失败项/已知例外/结论,先写 <路径>.new 再 mv(原子落盘)。渲染与旧内联实现逐字节一致。
dbk_write_accept_summary() {
  local p="$1" host="$2" side="$3" scr="$4" basis="$5" concl="$6" conf="$7" x i g s m c tag n=0
  local LINES=()
  mapfile -t LINES <<<"$(cat)"
  for x in ${LINES[@]+"${LINES[@]}"}; do IFS='|' read -r _ _ s _ _ <<<"$x"; [ "$s" = fail ] && n=$((n + 1)); done
  {
    printf '# 验收汇总:A-F 六组逐项判定\n\n- 设备:%s\n- 判定侧:%s\n- 生成时间:%s\n- 判定脚本:%s\n- 依据:%s\n\n' \
      "$host" "$side" "$(date '+%F %T%z')" "$scr" "$basis"
    printf '## 逐项结果\n\n| 项 | 组 | 结论 | 原因 | 关联卡 |\n|---|---|---|---|---|\n'
    for x in ${LINES[@]+"${LINES[@]}"}; do IFS='|' read -r i g s m c <<<"$x"
      case "$s" in pass) tag=PASS ;; fail) tag=FAIL ;; manual) if [ "$conf" -eq 1 ]; then tag='需人工(已确认)'; else tag=需人工; fi ;; *) tag=跳过 ;; esac
      printf '| %s | %s | %s | %s | %s |\n' "$i" "$g" "$tag" "$(printf '%s' "$m" | sed 's/|/\\|/g')" "$c"; done
    printf '\n## 失败项\n\n'
    for x in ${LINES[@]+"${LINES[@]}"}; do IFS='|' read -r i g s m c <<<"$x"; [ "$s" = fail ] && printf -- '- %s %s(关联卡 %s)\n' "$i" "$m" "$c"; done
    [ "$n" -eq 0 ] && printf '（无）\n'
    printf '\n## 已知例外\n\n未通过项的唯一合法归宿;逐条填写条目/原因/影响面/是否阻塞/后续动作,无例外时保留(无)。\n\n'
    printf '| 条目 | 原因 | 影响面 | 是否阻塞 | 后续动作 |\n|---|---|---|---|---|\n| （无） |  |  |  |  |\n\n## 结论\n\n结论: %s\n' "$concl"
  } >"$p.new" && mv "$p.new" "$p"
}
