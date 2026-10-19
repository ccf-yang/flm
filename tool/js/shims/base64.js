import { Buffer } from 'buffer'

export const btoa = (str) => Buffer.from(String(str), 'binary').toString('base64')
export const atob = (str) => Buffer.from(String(str), 'base64').toString('binary')
