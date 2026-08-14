---
type: research.mixed
label: งานวิจัยแบบผสม
description: งานวิจัยที่ใช้ทั้งเครื่องมือเชิงปริมาณและการเก็บข้อมูลเชิงคุณภาพในงานเดียวกัน
roles: teamLead, researcher, analyst, writer, reviewer
stages: initiation, planning, execution, closing
wbs_template: research-5-chapter
gate: G-instrument | after=instrument.draft | requires=content_validity_passed, consent_approved, ethics_recorded
gate: G-integration | after=analysis.both | requires=quantitative_done, qualitative_done, integration_stated
suggest_tailoring_out: procurement | งานวิจัยส่วนบุคคล ไม่มีการจัดซื้อจัดหา
dod_override: writer | ต้นฉบับที่บอกชัดว่าผลสองฝั่งถูกนำมาต่อกันตรงไหนและอย่างไร
---

งานผสมมีประตูเพิ่มอีกหนึ่ง คือจุดที่ผลสองฝั่งต้องถูกนำมาต่อกันจริง ไม่ใช่รายงานคู่กันเฉย ๆ
