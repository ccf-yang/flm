import CryptoJS from 'crypto-js'

export const stringMd5 = (str) => CryptoJS.MD5(String(str)).toString()
