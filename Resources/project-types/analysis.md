---
type: analysis
label: งานวิเคราะห์ข้อมูล
description: งานที่รับข้อมูลที่มีอยู่แล้วมาวิเคราะห์และรายงานผล ไม่ได้เก็บข้อมูลใหม่จากคน
roles: teamLead, analyst, writer, reviewer
stages: initiation, planning, execution, closing
wbs_template: analysis-report
gate: G-assumption | after=analysis.run | requires=assumptions_checked, source_recorded
suggest_tailoring_out: procurement | ใช้ข้อมูลที่มีอยู่แล้ว ไม่มีการจัดซื้อ
suggest_tailoring_out: orgChange | เป็นงานวิเคราะห์ ไม่ได้เปลี่ยนวิธีทำงานขององค์กร
dod_override: analyst | ผลที่รันซ้ำได้ พร้อมผลตรวจ assumption และที่มาของทุกตาราง
---

ไม่มีการเก็บข้อมูลจากคน จึงไม่มีประตูเครื่องมือ ประตูที่มีคือ assumption ของสถิติที่ใช้
และที่มาของข้อมูลที่ต้องชี้กลับได้
