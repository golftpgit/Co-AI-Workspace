---
type: software
label: งานซอฟต์แวร์
description: งานที่ส่งมอบเป็นซอฟต์แวร์ที่ใช้งานได้ ทีละรอบ
roles: teamLead, engineer, reviewer
stages: initiation, planning, execution, closing
wbs_template: software-increment
gate: G-release | after=increment.ready | requires=tests_green, reviewed_by_person
suggest_tailoring_out: procurement | พัฒนาเองทั้งหมด ไม่มีการจัดซื้อ
dod_override: engineer | โค้ดที่ merge แล้ว ผ่านเทสทั้งชุด และมีคนรีวิว
---

รอบส่งมอบหนึ่งรอบคือหน่วยของงานนี้ ประตูก่อนปล่อยคือเทสเขียวและมีคนรีวิว ไม่ใช่แค่คอมไพล์ผ่าน
